#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""央视影音（CBox）免 DRM 直播插件 v1.2.0（CCTVHost iOS 深度适配增强版）

数据来源：cn.vuclip.mobiletv 7.9.31（央视影音）IPA 逆向得到的两个公开配置
    https://api.live.cntv.cn/liveconfig/bcsioslivecbox_000.json   频道清单（776 路）
    https://api.live.cntv.cn/livestatic/zs/livestatic_config/unity_iosapp.json  直播策略

v1.1.3 CCTVHost 专项修复：
    1. 修复 ALPN 协议死锁：移除 set_alpn_protocols(['h2', 'http/1.1']) 里面的 'h2'，避免与 http.client (HTTP/1.1) 解析器冲突导致 TLS 握手后挂死或 BadStatusLine
    2. 修复 CCTVHost 嵌入式 Python 证书缺失：连接池自动降级并记忆无根证书环境；_urllib_fetch 同步注入免校验 SSLContext
    3. 修复流式代理分支遗漏：当存在系统代理且 stream=True 时不再走错误的手写 CONNECT 隧道
    4. 修复 --lan 绑定覆盖：仅当未显式指定非回环 --bind 时才被 --lan 覆盖，保留 CCTVHost 端口/环境变量约定
    5. 保留 O(N) 目录索引、候选线路并发竞速、实时窗口刷新（不静态缓存旧 m3u8）与可选分片预取

用法:
    python3 cbox_live_plugin.py --list
    python3 cbox_live_plugin.py --groups
    python3 cbox_live_plugin.py --check 20
    python3 cbox_live_plugin.py --url wgw01
    python3 cbox_live_plugin.py --m3u cbox.m3u
    python3 cbox_live_plugin.py --serve [--port 18768] [--lan] [--proxy-ts]
"""
from __future__ import annotations

import argparse
import base64
import collections
from concurrent.futures import Future, ThreadPoolExecutor, TimeoutError as FutureTimeout, as_completed
import gzip
import http.client
import ipaddress
import json
import os
import re
import secrets
import socket
import ssl
import sys
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

__version__ = '1.2.0'
UA = 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Safari/537.36'


def _make_ssl_ctx(verified=True):
    try:
        ctx = ssl.create_default_context() if verified else ssl._create_unverified_context()
    except Exception:
        ctx = ssl._create_unverified_context()
    try:
        # 绝不能加入 'h2'！http.client 仅支持 HTTP/1.x，协商出 h2 会导致服务端发二进制帧而客户端卡死
        ctx.set_alpn_protocols(['http/1.1'])
    except Exception:
        pass
    return ctx


_SSL_VERIFIED = _make_ssl_ctx(True)
_SSL_UNVERIFIED = _make_ssl_ctx(False)
# 嵌入式 iOS Python 常无根证书库，一旦检测到全局默认切换免校验，省去每次失败重连耗时
_GLOBAL_INSECURE_TLS = os.environ.get('PYTHONHTTPSVERIFY', '1') == '0'


def _proxy_config(scheme):
    """Return (proxy_host, proxy_port, proxy_auth_header) or None."""
    env_key = 'https_proxy' if scheme == 'https' else 'http_proxy'
    raw = os.environ.get(env_key) or os.environ.get(env_key.upper()) or ''
    raw = raw.strip()
    if not raw:
        return None
    try:
        p = urllib.parse.urlsplit(raw if '://' in raw else 'http://' + raw)
    except Exception:
        return None
    phost = p.hostname
    pport = p.port or 3128
    if not phost:
        return None
    auth = None
    if p.username:
        cred = urllib.parse.unquote(p.username)
        if p.password:
            cred += ':' + urllib.parse.unquote(p.password)
        auth = 'Basic ' + base64.b64encode(cred.encode('utf-8')).decode('ascii')
    return (phost, pport, auth)


def _proxy_for(scheme, host):
    """Proxy to use for (scheme, host), or None. Local hosts never proxy."""
    if not host:
        return None
    h = host.lower()
    if h in ('localhost', '127.0.0.1', '::1') or h.endswith('.local'):
        return None
    no_proxy = os.environ.get('no_proxy') or os.environ.get('NO_PROXY') or ''
    for entry in (e.strip().lower() for e in no_proxy.split(',') if e.strip()):
        if entry == '*' or h == entry or h.endswith('.' + entry.lstrip('.')):
            return None
    return _proxy_config(scheme)


class _BytesStreamAdapter:
    """将完整 bytes 包装成类 HTTPResponse 流对象，供代理模式下 stream=True 无缝复用。"""

    def __init__(self, data: bytes):
        self._buf = memoryview(data)
        self._pos = 0
        self.will_close = False

    def read(self, amt=None):
        if self._pos >= len(self._buf):
            return b''
        if amt is None or amt < 0:
            out = self._buf[self._pos:].tobytes()
            self._pos = len(self._buf)
            return out
        end = min(len(self._buf), self._pos + amt)
        out = self._buf[self._pos:end].tobytes()
        self._pos = end
        return out

    def isclosed(self):
        return self._pos >= len(self._buf)


import builtins as _builtins


def _read_body_chunked(resp, max_bytes=None):
    """以 <=64KB 分块读取响应体，并标记 _host_media_stream_read 以兼容 CCTVHost 并发预算与字节限额。"""
    if resp is None:
        return b''
    t = threading.current_thread()
    prev = getattr(t, '_host_media_stream_read', False)
    t._host_media_stream_read = True
    try:
        limit = int(max_bytes) if max_bytes is not None else 16 * 1024 * 1024
        buf = bytearray()
        while len(buf) < limit:
            step = min(65536, limit - len(buf))
            chunk = resp.read(step)
            if not chunk:
                break
            buf.extend(chunk)
        return bytes(buf)
    finally:
        t._host_media_stream_read = prev


class _SocketTrackingMixin:
    """http.client 连接混入：登记出站 socket，使 stop 能立即 shutdown 中断
    卡在代理 CONNECT / TLS 握手 / 响应读取里的后台任务，而不是等网络超时。
    注意两点：(1) http.client 经 self._create_connection 建连（类属性在
    import 时就绑定了 socket.create_connection），直接改 socket.create_connection
    全局是拦不到的，必须覆写 _create_connection；(2) wrap_socket 会 detach
    明文 socket（fileno 变成 -1），登记它对握手无效，所以 HTTPS 手动 wrap
    （do_handshake_on_connect=False），登记活的 SSLSocket 后再显式握手。
    （拦截窗口内的其它线程若恰好也在建连，其 socket 也会被登记；stop 时
    一并关闭是期望行为，超时兜底仍在。）"""

    @staticmethod
    def _create_connection(address, timeout=None, source_address=None):
        sock = socket.create_connection(
            address, timeout=timeout, source_address=source_address)
        _register_socket(sock)
        return sock

    def connect(self):
        if isinstance(self, http.client.HTTPSConnection):
            # 明文 TCP 建连（+ 代理 CONNECT），再手动 TLS wrap。
            http.client.HTTPConnection.connect(self)
            plain = self.sock
            server_hostname = self._tunnel_host if self._tunnel_host else self.host
            self.sock = self._context.wrap_socket(
                self.sock, server_hostname=server_hostname,
                do_handshake_on_connect=False)
            _unregister_socket(plain)
            _register_socket(self.sock)
            try:
                self.sock.do_handshake()
            except BaseException:
                _unregister_socket(self.sock)
                raise
        else:
            super().connect()

    def close(self):
        _unregister_socket(getattr(self, 'sock', None))
        super().close()


class _TrackedHTTPConnection(_SocketTrackingMixin, http.client.HTTPConnection):
    pass


class _TrackedHTTPSConnection(_SocketTrackingMixin, http.client.HTTPSConnection):
    pass


class _TrackedHTTPHandler(urllib.request.HTTPHandler):
    def http_open(self, req):
        return self.do_open(_TrackedHTTPConnection, req)


class _TrackedHTTPSHandler(urllib.request.HTTPSHandler):
    def https_open(self, req):
        return self.do_open(_TrackedHTTPSConnection, req, context=self._context,
                            check_hostname=self._check_hostname)


def _urllib_fetch(url, headers=None, timeout=15.0, max_bytes=None):
    """Fetch via urllib (honors proxy env vars + unverified SSL fallback)."""
    global _GLOBAL_INSECURE_TLS
    hdrs = dict(headers or {})
    hdrs.setdefault('User-Agent', UA)
    req = urllib.request.Request(url, headers=hdrs, method='GET')
    for attempt in (0, 1):
        ctx = _SSL_UNVERIFIED if (_GLOBAL_INSECURE_TLS or attempt == 1) else _SSL_VERIFIED
        try:
            opener = urllib.request.build_opener(
                _TrackedHTTPHandler(), _TrackedHTTPSHandler(context=ctx),
                urllib.request.ProxyHandler(),
            )
            with opener.open(req, timeout=timeout) as resp:
                data = _read_body_chunked(resp, max_bytes=max_bytes)
                ce = (resp.headers.get('Content-Encoding') or '').lower() if resp.headers else ''
                if 'gzip' in ce or data[:2] == b'\x1f\x8b':
                    try:
                        data = gzip.decompress(data)
                    except Exception:
                        pass
                return data, resp.geturl()
        except urllib.error.HTTPError as e:
            raise PluginError('HTTP %d (%s)' % (e.code, url[:80])) from e
        except Exception as e:
            if attempt == 0 and ('CERTIFICATE_VERIFY_FAILED' in str(e) or isinstance(e, ssl.SSLError)):
                _GLOBAL_INSECURE_TLS = True
                continue
            raise PluginError('网络请求失败 (%s): %s' % (urllib.parse.urlsplit(url).hostname or '', e)) from e


LIVESTATIC = 'https://api.live.cntv.cn/livestatic/zs/livestatic_config/unity_iosapp.json'
LIVECONFIG = 'https://api.live.cntv.cn/liveconfig/bcsioslivecbox_000.json'
CNTV_EPG = 'https://api.cntv.cn/epg/getEpgInfoByChannelNew'

GROUP_LABEL = {
    'livechina': '直播中国',
    'ldncctv': '央视', 'ldcctv': '央视', 'ldocctv': '央视', 'wstv': '卫视',
    'cetv': '教育台', 'sports': '体育', 'mlive': '移动直播', 'tiyuvip-cctv': '体育VIP',
    'tiyuvip-sports': '体育VIP',
    'gc': '熊猫频道',
    'gchd': '熊猫高清',
    'studio': '演播室',
    'ncpalive': '国家大剧院',
    '12371live': '党员网',
    'ceshi2': '测试',
}
GROUP_ORDER = [
    'ldncctv', 'ldcctv', 'ldocctv', 'wstv', 'cetv', 'sports',
    'livechina', 'gc', 'gchd', 'studio', 'ncpalive', '12371live', 'ceshi2'
]

NAME_MAP = {
    'stduio1': '演播室1', 'stduio4': '演播室4',
    'zhengxie': '政协', 'zhengxie02': '政协02',
    'ipanda': '熊猫频道', 'ipanda1000': '熊猫频道1000',
    'xiongmaopindao01': '熊猫频道01',
    'ncpa': '国家大剧院', 'ncpavip': '国家大剧院VIP',
    'dangyuanwang': '党员网',
}
_CCTV_NAMES = {
    'cctv1': 'CCTV-1 综合', 'cctv2': 'CCTV-2 财经', 'cctv3': 'CCTV-3 综艺',
    'cctv4': 'CCTV-4 中文国际', 'cctv5': 'CCTV-5 体育', 'cctv5plus': 'CCTV-5+ 体育赛事',
    'cctv6': 'CCTV-6 电影', 'cctv7': 'CCTV-7 国防军事', 'cctv8': 'CCTV-8 电视剧',
    'cctvjilu': 'CCTV-9 纪录', 'cctv9': 'CCTV-9 纪录', 'cctv10': 'CCTV-10 科教',
    'cctv11': 'CCTV-11 戏曲', 'cctv12': 'CCTV-12 社会与法', 'cctv13': 'CCTV-13 新闻',
    'cctv14': 'CCTV-14 少儿', 'cctv15': 'CCTV-15 音乐', 'cctv16': 'CCTV-16 奥林匹克',
    'cctv17': 'CCTV-17 农业农村', 'cctv4k': 'CCTV-4K 超高清', 'cctv8k': 'CCTV-8K 超高清',
    'cctvamerica': 'CCTV 美洲', 'cctveurope': 'CCTV 欧洲',
}
_WSTV_NAMES = {
    'btv1': '北京卫视', 'dongfang': '东方卫视', 'guangdong': '广东卫视', 'anhui': '安徽卫视',
    'dongnan': '东南卫视', 'guangxi': '广西卫视', 'hebei': '河北卫视', 'henan': '河南卫视',
    'heilongjiang': '黑龙江卫视', 'hubei': '湖北卫视', 'hunan': '湖南卫视', 'jiangsu': '江苏卫视',
    'jiangxi': '江西卫视', 'jilin': '吉林卫视', 'liaoning': '辽宁卫视', 'neimenggu': '内蒙古卫视',
    'ningxia': '宁夏卫视', 'qinghai': '青海卫视', 'shandong': '山东卫视', 'shanxi1': '山西卫视',
    'shan1xi': '山西卫视', 'shan3xi': '陕西卫视', 'shenzhen': '深圳卫视', 'sichuan': '四川卫视',
    'tianjin': '天津卫视', 'xinjiang': '新疆卫视', 'yunnan': '云南卫视', 'zhejiang': '浙江卫视',
    'chongqing': '重庆卫视', 'guizhou': '贵州卫视', 'gansu': '甘肃卫视', 'hainan': '海南卫视',
    'xizang': '西藏卫视', 'shaanxi': '陕西卫视', 'xianggangweishi': '香港卫视',
}
NAME_MAP.update(_CCTV_NAMES)
NAME_MAP.update(_WSTV_NAMES)
for _i in range(1, 31):
    NAME_MAP.setdefault('xiongmao%02d' % _i, '熊猫机位%02d' % _i)

AVAILABLE_BUILTIN = [
    'ahhs01', 'anhui', 'blg03', 'blg05', 'bsszbcs', 'bsszjs', 'bsszxer',
    'btv1', 'btv2', 'btv3', 'btv5', 'btv7', 'btv9',
    'cctv1', 'cctv10', 'cctv11', 'cctv12', 'cctv13', 'cctv14', 'cctv15', 'cctv17',
    'cctv2', 'cctv4', 'cctv7', 'cctv9', 'cctvamerica', 'cctveurope',
    'cetv1', 'cetv2', 'cetv3', 'cetv4', 'chongqing', 'cntv411-zbzg', 'dangyuanwang',
    'dhyyqsm', 'dhyyqst', 'djd01', 'djyqyl1', 'dlst01', 'dlst03', 'dongfang', 'dongnan',
    'drs01', 'emsarm', 'emspxps', 'emswfs', 'emsyh', 'fcw03', 'fhgcdgm', 'fhgcdnhs',
    'gansu', 'gccntv241-slf01', 'gllj01', 'gly01', 'guangdong', 'guangxi', 'guizhou',
    'hebei', 'heilongjiang', 'henan', 'hgsspzxdpb', 'hkts02', 'hkts03', 'hkts07', 'hkts09',
    'hkylxs01', 'hkylxs03', 'hkylxs05', 'hkylxs06', 'hlwcc', 'hlwxt', 'hlzycc', 'hnttbdjd',
    'hsptgy', 'hspyt', 'hssxf', 'hswlf', 'hsxhdxg', 'hsxksqj', 'hsyg', 'hubei', 'ipanda',
    'jhs01', 'jhs05', 'jiangxi', 'jilin', 'liaoning', 'ljgcdsc', 'ljgcdyhxgjt', 'ljgcszsnkgc',
    'ljgcwglytylxs', 'lpsgmjng01', 'lsdfgfl', 'mdjxxdsb', 'mdjxxmhjyxj', 'mlive29', 'mlive33',
    'mlive38', 'mlive42', 'mlive43', 'mlive44', 'mlive45', 'mlive46', 'mlive47', 'mlive48',
    'mlive49', 'mlive53', 'mlive56', 'mlive59', 'mlive66', 'mlive69', 'ncpa', 'neimenggu',
    'neimenggu2', 'ningxia', 'nss01', 'nxspthhpl', 'pshdxg01', 'pts01', 'qdls02', 'qdls03',
    'qinghai', 'sgns02', 'shan1xi', 'shan3xi', 'shandong', 'shenzhen', 'sichuan', 'taishan01',
    'taishan02', 'taishan03', 'taishan05', 'taishan06', 'tianjin', 'tiyuip17', 'tjhh02',
    'tms05', 'travel', 'tyhjtys', 'wgw01', 'wgw02', 'wgw03', 'wgw05', 'wysynf', 'wysyxdhp',
    'xianggangweishi', 'xinjiang', 'xiongmao01', 'xiongmao02', 'xiongmao03', 'xiongmao04',
    'xiongmao05', 'xiongmao06', 'xiongmao07', 'xiongmao08', 'xiongmao09', 'xiongmao10',
    'xiongmao27', 'xiongmao28', 'xiongmao29', 'xizang', 'xjtcdgs', 'xjtcdhsz', 'xjtcmys',
    'xwh01', 'xywfl', 'ylh04', 'ylxs11', 'ylxs12', 'yunnan', 'yxhcnh', 'yxlcyt', 'yxxdpf',
    'zh02', 'zh03', 'zjjbfh', 'zjjjjdl', 'zjjmht', 'zjjsrsm', 'zjjybf', 'zjwzbblh',
    'zjwzblt', 'zjwzlxt', 'zjwzlyhb', 'zsslsfwsgz', 'zsslsjjfsd', 'zsslstpt', 'ztd',
    'ztn', 'zyqcdx01'
]

def _resolve_data_dir(explicit_dir=''):
    for cand in (
        explicit_dir,
        os.environ.get('CCTVHOST_DATA_DIR', ''),
        os.environ.get('CBOX_DATA_DIR', ''),
        os.environ.get('YSP_DATA_DIR', ''),
        os.path.dirname(os.path.abspath(__file__)) if '__file__' in globals() else os.getcwd(),
    ):
        if cand and cand.strip():
            d = os.path.abspath(cand.strip())
            try:
                os.makedirs(d, exist_ok=True)
                return d
            except OSError:
                continue
    return os.getcwd()


BASE_DIR = _resolve_data_dir()
AVAIL_JSON = os.path.join(BASE_DIR, 'cbox-available.json')
QUIET = False
PROXY_TS_DEFAULT = os.environ.get('CBOX_PROXY_TS', '').strip().lower() in ('1', 'true', 'yes')
AUTH_TOKEN = os.environ.get('CBOX_TOKEN', '').strip()
ORIGIN = os.environ.get('CBOX_ORIGIN', '')
_STOP_EVENT = threading.Event()
_ACTIVE_SERVERS = []
_ACTIVE_SERVERS_LOCK = threading.Lock()

# 在途出站 socket 注册表：stop 时立即 shutdown 正在握手/读写中的
# socket，使卡在代理 CONNECT、TLS 握手或响应读取里的后台任务立刻退出，
# 而不是等到各自的网络超时（最长 12s）。只登记本插件经 _urllib_fetch
# 或 HttpPool 发起的出站连接；入站 HTTP 服务的 socket 不在此列。
_ACTIVE_SOCKETS = set()
_ACTIVE_SOCKETS_LOCK = threading.Lock()


def _register_socket(sock):
    if sock is None:
        return
    with _ACTIVE_SOCKETS_LOCK:
        _ACTIVE_SOCKETS.add(sock)


def _unregister_socket(sock):
    if sock is None:
        return
    with _ACTIVE_SOCKETS_LOCK:
        _ACTIVE_SOCKETS.discard(sock)


def _close_active_sockets():
    with _ACTIVE_SOCKETS_LOCK:
        socks = list(_ACTIVE_SOCKETS)
        _ACTIVE_SOCKETS.clear()
    for sock in socks:
        try:
            sock.shutdown(socket.SHUT_RDWR)
        except Exception:
            pass
        try:
            sock.close()
        except Exception:
            pass


class _LazyBgPoolProxy:
    """按需初始化后台线程池，避免空闲线程阻塞 CCTVHost session.clean()，并在停止时立即回收。"""
    def __init__(self, max_workers=2):
        self._max_workers = max_workers
        self._pool = None
        self._lock = threading.Lock()

    def submit(self, fn, *args, **kwargs):
        if _STOP_EVENT.is_set():
            raise RuntimeError('service is stopping')
        with self._lock:
            if self._pool is None:
                self._pool = ThreadPoolExecutor(max_workers=self._max_workers, thread_name_prefix='cbox-bg')
            return self._pool.submit(fn, *args, **kwargs)

    def shutdown(self, wait=False, cancel_futures=True):
        with self._lock:
            pool, self._pool = self._pool, None
        if pool is not None:
            try:
                pool.shutdown(wait=wait, cancel_futures=cancel_futures)
            except TypeError:
                pool.shutdown(wait=wait)


def _detect_default_port():
    for name in ('CCTVHOST_PORT', 'CBOX_PORT', 'YSP2_PORT', 'YSP_PORT', 'PORT', 'SERVER_PORT', 'MINIS_PORT', 'HTTP_PORT'):
        v = os.environ.get(name)
        if v and v.strip().isdigit():
            p = int(v.strip())
            if 1 <= p <= 65535:
                return p
    return 18768


PORT = _detect_default_port()
MAX_CONCURRENT_CONNS = int(os.environ.get('CBOX_MAX_CONNS', '64'))
START_TIME = time.time()


class PluginError(RuntimeError):
    pass


# ================================================================ 日志
_LOG_RING = collections.deque(maxlen=200)
_LOG_LOCK = threading.Lock()
_LAST_SEEN = collections.OrderedDict()


def log(msg, min_interval=0.0):
    if QUIET:
        return
    text = str(msg).strip()
    if not text:
        return
    now = time.time()
    with _LOG_LOCK:
        if min_interval > 0:
            prev = _LAST_SEEN.get(text)
            if prev is not None and now - prev < min_interval:
                return
            _LAST_SEEN[text] = now
            _LAST_SEEN.move_to_end(text)
            while len(_LAST_SEEN) > 500:
                _LAST_SEEN.popitem(last=False)
        line = '[%s] %s' % (time.strftime('%H:%M:%S'), text)
        _LOG_RING.append(line)
    sys.stderr.write(line + '\n')


# ================================================================ HTTP 连接池
class HttpPool:
    """线程安全 Keep-Alive 连接池，支持 gzip 自动解压、重定向与流式读取。"""

    def __init__(self, max_per_host=8, idle_ttl=30.0):
        self.max_per_host = max_per_host
        self.idle_ttl = idle_ttl
        self._lock = threading.Lock()
        self._pool = collections.defaultdict(collections.deque)
        self._insecure_hosts = set()
        self.reused = 0
        self.created = 0

    def _get_conn(self, scheme, host, port, timeout):
        key = (scheme, host, port)
        now = time.time()
        with self._lock:
            dq = self._pool[key]
            while dq:
                conn, ts = dq.pop()
                if now - ts <= self.idle_ttl and conn.sock is not None:
                    self.reused += 1
                    conn.timeout = timeout
                    try:
                        conn.sock.settimeout(timeout)
                        return conn, True
                    except OSError:
                        try:
                            conn.close()
                        except Exception:
                            pass
                else:
                    try:
                        conn.close()
                    except Exception:
                        pass
            insecure = _GLOBAL_INSECURE_TLS or (host in self._insecure_hosts)
            self.created += 1
        if scheme == 'https':
            ctx = _SSL_UNVERIFIED if insecure else _SSL_VERIFIED
            return _TrackedHTTPSConnection(host, port, timeout=timeout, context=ctx), False
        return _TrackedHTTPConnection(host, port, timeout=timeout), False

    def _put_conn(self, scheme, host, port, conn):
        if conn is None or conn.sock is None:
            return
        key = (scheme, host, port)
        with self._lock:
            dq = self._pool[key]
            if len(dq) >= self.max_per_host:
                old, _ = dq.popleft()
                try:
                    old.close()
                except Exception:
                    pass
            dq.append((conn, time.time()))

    def mark_insecure(self, host):
        global _GLOBAL_INSECURE_TLS
        _GLOBAL_INSECURE_TLS = True
        with self._lock:
            self._insecure_hosts.add(host)

    def stats(self):
        with self._lock:
            idle = sum(len(dq) for dq in self._pool.values())
            return {'idle': idle, 'reused': self.reused, 'created': self.created}

    def request(self, url, headers=None, timeout=15.0, max_bytes=None, max_redirects=5, stream=False):
        cur_url = url
        base_headers = dict(headers or {})
        base_headers.setdefault('User-Agent', UA)
        base_headers.setdefault('Connection', 'keep-alive')
        base_headers.setdefault('Accept-Encoding', 'gzip')

        _p0 = urllib.parse.urlsplit(cur_url)
        if _proxy_for((_p0.scheme or 'http').lower(), _p0.hostname or '') is not None:
            data, final_url = _urllib_fetch(cur_url, headers=base_headers, timeout=timeout, max_bytes=max_bytes)
            if stream:
                return _BytesStreamAdapter(data), final_url, len(data), (lambda ok=True: None)
            return data, final_url, len(data), None

        for _ in range(max_redirects + 1):
            p = urllib.parse.urlsplit(cur_url)
            scheme = (p.scheme or 'http').lower()
            host = p.hostname or ''
            port = p.port or (443 if scheme == 'https' else 80)
            path = (p.path or '/') + (('?' + p.query) if p.query else '')
            hdrs = dict(base_headers)
            hdrs['Host'] = host if p.port is None else '%s:%d' % (host, port)

            last_err = None
            for attempt in (0, 1):
                conn, from_pool = self._get_conn(scheme, host, port, timeout)
                try:
                    conn.request('GET', path, headers=hdrs)
                    resp = conn.getresponse()
                    break
                except ssl.SSLCertVerificationError:
                    try:
                        conn.close()
                    except Exception:
                        pass
                    self.mark_insecure(host)
                    continue
                except (http.client.HTTPException, OSError, ssl.SSLError) as e:
                    try:
                        conn.close()
                    except Exception:
                        pass
                    last_err = e
                    if 'CERTIFICATE_VERIFY_FAILED' in str(e) or isinstance(e, ssl.SSLError):
                        self.mark_insecure(host)
                        continue
                    if from_pool and attempt == 0:
                        continue
                    raise PluginError('网络请求失败 (%s): %s' % (host, e)) from e
            else:
                raise PluginError('网络请求重试失败 (%s): %s' % (host, last_err))

            status = resp.status
            if status in (301, 302, 303, 307, 308):
                loc = resp.getheader('Location')
                _read_body_chunked(resp, max_bytes=1024 * 1024)
                if resp.will_close:
                    conn.close()
                else:
                    self._put_conn(scheme, host, port, conn)
                if not loc:
                    raise PluginError('HTTP %d 缺少 Location' % status)
                cur_url = urllib.parse.urljoin(cur_url, loc)
                continue

            if status not in (200, 206):
                _read_body_chunked(resp, max_bytes=512)
                if resp.will_close:
                    conn.close()
                else:
                    self._put_conn(scheme, host, port, conn)
                raise PluginError('HTTP %d (%s)' % (status, cur_url[:80]))

            ce = (resp.getheader('Content-Encoding') or '').lower()
            cl_raw = resp.getheader('Content-Length')
            cl = int(cl_raw) if cl_raw and cl_raw.isdigit() else None

            if stream and 'gzip' not in ce:
                def _release(ok=True):
                    try:
                        if ok and not resp.will_close and resp.isclosed():
                            self._put_conn(scheme, host, port, conn)
                        else:
                            conn.close()
                    except Exception:
                        try:
                            conn.close()
                        except Exception:
                            pass
                return resp, cur_url, cl, _release

            if max_bytes is not None:
                data = _read_body_chunked(resp, max_bytes=max_bytes)
                if cl is None or cl > max_bytes:
                    conn.close()
                elif not resp.will_close:
                    self._put_conn(scheme, host, port, conn)
                else:
                    conn.close()
            else:
                data = _read_body_chunked(resp)
                if resp.will_close:
                    conn.close()
                else:
                    self._put_conn(scheme, host, port, conn)

            if 'gzip' in ce or data[:2] == b'\x1f\x8b':
                try:
                    data = gzip.decompress(data)
                except Exception:
                    pass
            return data, cur_url, len(data), None

        raise PluginError('重定向次数过多: %s' % cur_url)

    def close_all(self):
        # 同步关闭正在读写/握手的在途连接，否则 stop 要等到网络超时。
        _close_active_sockets()
        with self._lock:
            pools = list(self._pool.values())
            self._pool.clear()
        for q in pools:
            while q:
                _, conn = q.popleft()
                try:
                    conn.close()
                except Exception:
                    pass


_HTTP_POOL = HttpPool()
_BG_POOL = _LazyBgPoolProxy(max_workers=2)


def _get(url, timeout=15.0, headers=None, max_bytes=None):
    data, _, _, _ = _HTTP_POOL.request(url, headers=headers, timeout=timeout, max_bytes=max_bytes)
    return data


def _fetch_text(url, timeout=10.0):
    data, final_url, _, _ = _HTTP_POOL.request(url, timeout=timeout, max_bytes=262144)
    return data.decode('utf-8', 'replace'), final_url


# ================================================================ 目录与候选线路（O(N) 索引）
_CATALOG = {'ts': 0.0, 'items': [], 'by_code': {}, 'cands_map': {}, 'logos': {}, 'lock': threading.Lock()}
_POLICY = {'conf': None}


def _build_candidates_map(conf):
    """单次扫描 live_policy 构建 code -> [candidate_urls] 字典，复杂度 O(N)。"""
    nd_map = collections.defaultdict(list)
    udrm_map = collections.defaultdict(list)
    for policy in conf.get('live_policy') or []:
        manifests = policy.get('cn_manifest') or {}
        nd_tpls, udrm_tpls = [], []
        for key, val in manifests.items():
            if not (key == 'hls_nd' or key.startswith('hls_udrm')):
                continue
            vals = [val] if isinstance(val, str) else list(val or [])
            for t in vals:
                if isinstance(t, str) and '${channel}' in t and 'timebase' not in t:
                    if key == 'hls_nd':
                        nd_tpls.append(t)
                    else:
                        udrm_tpls.append(t)
        if not nd_tpls and not udrm_tpls:
            continue
        for ch in policy.get('channels') or []:
            code = (ch.get('channel') or '').strip()
            if not code:
                continue
            for t in nd_tpls:
                u = t.replace('${channel}', code)
                if u not in nd_map[code]:
                    nd_map[code].append(u)
            for t in udrm_tpls:
                u = t.replace('${channel}', code)
                if u not in udrm_map[code] and u not in nd_map[code]:
                    udrm_map[code].append(u)
    out = {}
    all_codes = set(nd_map.keys()) | set(udrm_map.keys())
    for c in all_codes:
        # 优先仅保留明文 hls_nd 线路；仅当某频道无任何 hls_nd 模板时才回退尝试 hls_udrm
        if nd_map[c]:
            out[c] = list(nd_map[c])
        else:
            out[c] = list(udrm_map[c])
    return out


DEFAULT_LOGO_BASE = 'https://app.cctv.com/special/appchannellogo/square/l'
OFFICIAL_LOGOS = {
    'cctv4k': 'https://app.cctv.com/special/appchannellogo/square/l/cctv4K.png?q=75',
    'cctv8k': 'https://app.cctv.com/special/appchannellogo/square/l/cctv8K.png?q=75',
    'cctv16': 'https://p3.img.cctvpic.com/photoAlbum/page/performance/img/2021/10/22/1634889304044_685.png',
    'btv1': 'https://p3.img.cctvpic.com/photoAlbum/page/performance/img/2026/2/5/1770272590497_949.png',
    'chongqing': 'https://p3.img.cctvpic.com/photoAlbum/page/performance/img/2022/4/8/1649386058290_834.png',
    'dongnan': 'https://app.cctv.com/special/appchannellogo/square/l/fujian.png?q=75',
    'shan1xi': 'https://app.cctv.com/special/appchannellogo/square/l/shanxi.png?q=75',
    'shan3xi': 'https://app.cctv.com/special/appchannellogo/square/l/shaanxi.png?q=75',
    'cetv3': 'https://p3.img.cctvpic.com/photoAlbum/page/performance/img/2021/4/2/1617352119273_679.png',
    'cetv4': 'https://p3.img.cctvpic.com/photoAlbum/page/performance/img/2020/12/15/1608024829270_177.png',
}


def get_default_logo(code):
    if code in OFFICIAL_LOGOS:
        return OFFICIAL_LOGOS[code]
    if code.startswith(('cctv', 'cetv', 'btv')) or code in _WSTV_NAMES:
        return '%s/%s.png?q=75' % (DEFAULT_LOGO_BASE, code)
    return ''


_BUILTIN_TEMPLATES = [
    'https://hls.cntv.myhwcdn.cn/asp/hls/main/0303000a/3/default/%s/main.m3u8',
    'https://hls.cntv.lxdns.com/asp/hls/main/0303000a/3/default/%s/main.m3u8',
]
_BUILTIN_CHANNEL_SPECS = [
    ('ldncctv', 'cctv1', 'CCTV-1 综合'),
    ('ldncctv', 'cctv2', 'CCTV-2 财经'),
    ('ldncctv', 'cctv3', 'CCTV-3 综艺'),
    ('ldncctv', 'cctv4', 'CCTV-4 中文国际'),
    ('ldncctv', 'cctv5', 'CCTV-5 体育'),
    ('ldncctv', 'cctv5plus', 'CCTV-5+ 体育赛事'),
    ('ldncctv', 'cctv6', 'CCTV-6 电影'),
    ('ldncctv', 'cctv7', 'CCTV-7 国防军事'),
    ('ldncctv', 'cctv8', 'CCTV-8 电视剧'),
    ('ldncctv', 'cctv9', 'CCTV-9 纪录'),
    ('ldncctv', 'cctv10', 'CCTV-10 科教'),
    ('ldncctv', 'cctv11', 'CCTV-11 戏曲'),
    ('ldncctv', 'cctv12', 'CCTV-12 社会与法'),
    ('ldncctv', 'cctv13', 'CCTV-13 新闻'),
    ('ldncctv', 'cctv14', 'CCTV-14 少儿'),
    ('ldncctv', 'cctv15', 'CCTV-15 音乐'),
    ('ldncctv', 'cctv16', 'CCTV-16 奥林匹克'),
    ('ldncctv', 'cctv17', 'CCTV-17 农业农村'),
    ('ldncctv', 'cctv4k', 'CCTV-4K 超高清'),
    ('ldncctv', 'cctvamerica', 'CCTV 美洲'),
    ('ldncctv', 'cctveurope', 'CCTV 欧洲'),
    ('wstv', 'btv1', '北京卫视'),
    ('wstv', 'dongfang', '东方卫视'),
    ('wstv', 'hunan', '湖南卫视'),
    ('wstv', 'zhejiang', '浙江卫视'),
    ('wstv', 'jiangsu', '江苏卫视'),
    ('wstv', 'guangdong', '广东卫视'),
    ('wstv', 'shenzhen', '深圳卫视'),
    ('wstv', 'shandong', '山东卫视'),
    ('wstv', 'sichuan', '四川卫视'),
    ('wstv', 'hubei', '湖北卫视'),
    ('wstv', 'liaoning', '辽宁卫视'),
    ('wstv', 'anhui', '安徽卫视'),
    ('wstv', 'chongqing', '重庆卫视'),
    ('wstv', 'heilongjiang', '黑龙江卫视'),
    ('wstv', 'jiangxi', '江西卫视'),
    ('wstv', 'dongnan', '东南卫视'),
    ('wstv', 'henan', '河南卫视'),
    ('wstv', 'hebei', '河北卫视'),
    ('wstv', 'guangxi', '广西卫视'),
    ('wstv', 'guizhou', '贵州卫视'),
    ('wstv', 'yunnan', '云南卫视'),
    ('wstv', 'tianjin', '天津卫视'),
    ('cetv', 'cetv1', 'CETV-1'),
    ('cetv', 'cetv2', 'CETV-2'),
    ('cetv', 'cetv4', 'CETV-4'),
    ('gc', 'ipanda', '熊猫频道'),
]


def _build_builtin_catalog():
    items, by_code_map, cands_map = [], {}, {}
    for grp, code, name in _BUILTIN_CHANNEL_SPECS:
        cands = [tpl % code for tpl in _BUILTIN_TEMPLATES]
        cands_map[code] = cands
        it = {
            'group': grp,
            'code': code,
            'name': name,
            'logo': get_default_logo(code),
            'url': cands[0],
            'candidates': len(cands),
        }
        items.append(it)
        by_code_map[code] = it
    return items, by_code_map, cands_map


_CATALOG_REFRESHING = False


def _enrich_from_liveconfig(timeout=4.0):
    """可选拉取 LIVECONFIG 补充官方频道中文名与台标。"""
    logos = {}
    try:
        raw = _get(LIVECONFIG, timeout=timeout)
        data = json.loads(raw.decode('utf-8', 'replace'))
        items = data if isinstance(data, list) else (
            data.get('data') or data.get('channels') or data.get('list') or [])
        if isinstance(items, dict):
            items = list(items.values())
        for it in items:
            if not isinstance(it, dict):
                continue
            code = str(it.get('channelId') or it.get('channel') or it.get('id') or '').strip()
            name = str(it.get('title') or it.get('name') or it.get('channelName') or '').strip()
            logo = str(it.get('img') or it.get('logo') or it.get('icon') or '').strip()
            if code and name and code not in NAME_MAP:
                NAME_MAP[code] = name
            if code and logo:
                logos[code] = logo
    except Exception:
        pass
    return logos


def _refresh_catalog_remote(timeout=10.0):
    global _CATALOG_REFRESHING
    try:
        raw = _get(LIVESTATIC, timeout)
        conf = json.loads(raw.decode('utf-8', 'replace'))
        logos = _enrich_from_liveconfig(timeout=3.5)
        cands_map = _build_candidates_map(conf)
        items, seen, by_code_map = [], set(), {}
        _POLICY['conf'] = conf

        for policy in conf.get('live_policy') or []:
            group = policy.get('channel_group') or 'other'
            for ch in policy.get('channels') or []:
                code = (ch.get('channel') or '').strip()
                if not code or code in seen:
                    continue
                seen.add(code)
                cands = cands_map.get(code) or []
                if not cands:
                    continue
                ch_name = (ch.get('title') or ch.get('name') or '').strip()
                item = {
                    'group': group,
                    'code': code,
                    'name': NAME_MAP.get(code) or ch_name or _pretty(code, group),
                    'logo': logos.get(code) or get_default_logo(code),
                    'url': cands[0],
                    'candidates': len(cands),
                }
                items.append(item)
                by_code_map[code] = item

        order = {g: i for i, g in enumerate(GROUP_ORDER)}
        items.sort(key=lambda x: (order.get(x['group'], 99), x['code']))
        if items:
            with _CATALOG['lock']:
                _CATALOG['items'] = items
                _CATALOG['by_code'] = by_code_map
                _CATALOG['cands_map'] = cands_map
                _CATALOG['logos'] = logos
                _CATALOG['ts'] = time.time()
            return items
    finally:
        _CATALOG_REFRESHING = False
    return []


def load_catalog(timeout=12.0, non_blocking=False):
    """解析直播策略，返回 [{group, code, name, logo, url, candidates}]。"""
    global _CATALOG_REFRESHING
    with _CATALOG['lock']:
        if _CATALOG['items'] and time.time() - _CATALOG['ts'] < 1800:
            if not _CATALOG['by_code']:
                _CATALOG['by_code'] = {it['code']: it for it in _CATALOG['items'] if isinstance(it, dict) and it.get('code')}
            return _CATALOG['items']
        if non_blocking:
            if not _CATALOG['items']:
                b_items, b_by_code, b_cands = _build_builtin_catalog()
                _CATALOG['items'] = b_items
                _CATALOG['by_code'] = b_by_code
                _CATALOG['cands_map'] = b_cands
            if not _CATALOG_REFRESHING and not _STOP_EVENT.is_set():
                _CATALOG_REFRESHING = True
                try:
                    _BG_POOL.submit(_refresh_catalog_remote, timeout)
                except Exception:
                    _CATALOG_REFRESHING = False
            return _CATALOG['items']

    try:
        items = _refresh_catalog_remote(timeout=timeout)
        if items:
            return items
    except Exception as e:  # noqa: BLE001
        with _CATALOG['lock']:
            if _CATALOG['items']:
                return _CATALOG['items']
            b_items, b_by_code, b_cands = _build_builtin_catalog()
            _CATALOG['items'] = b_items
            _CATALOG['by_code'] = b_by_code
            _CATALOG['cands_map'] = b_cands
            _CATALOG['ts'] = time.time()
            log('远端直播策略暂不可用，使用内置核心频道目录兜底: %s' % e)
            return b_items
    with _CATALOG['lock']:
        if not _CATALOG['items']:
            b_items, b_by_code, b_cands = _build_builtin_catalog()
            _CATALOG['items'] = b_items
            _CATALOG['by_code'] = b_by_code
            _CATALOG['cands_map'] = b_cands
        return _CATALOG['items']


def _pretty(code, group):
    if group == 'livechina':
        return code
    base = GROUP_LABEL.get(group, group)
    m = re.fullmatch(r'([a-z]+?)(\d+)', code)
    return '%s %s' % (base, m.group(2)) if m else code


def candidate_urls(code):
    """同一频道的所有候选清单地址：优先使用 O(1) 预构建索引。"""
    with _CATALOG['lock']:
        cands = _CATALOG['cands_map'].get(code)
    if cands is not None:
        return list(cands)
    conf = _POLICY.get('conf')
    if conf:
        cands_map = _build_candidates_map(conf)
        with _CATALOG['lock']:
            _CATALOG['cands_map'] = cands_map
        return list(cands_map.get(code, []))
    return []


def load_avail():
    try:
        with open(AVAIL_JSON, encoding='utf-8') as f:
            d = json.load(f)
        codes = set(d.get('codes') or [])
        if codes:
            return codes
    except Exception:  # noqa: BLE001
        pass
    return set(AVAILABLE_BUILTIN)


def save_avail(codes):
    tmp = AVAIL_JSON + '.tmp'
    try:
        with open(tmp, 'w', encoding='utf-8') as f:
            json.dump({'ts': int(time.time()), 'codes': sorted(codes)}, f)
        os.replace(tmp, AVAIL_JSON)
    except OSError as e:
        log('可用列表写入失败: %s' % e)


def visible_items(non_blocking=True):
    items = load_catalog(non_blocking=non_blocking)
    avail = load_avail()
    filtered = [it for it in items if it['code'] in avail] if avail else items
    return filtered if filtered else items


def by_code(code, items=None):
    if items is None:
        load_catalog()
        with _CATALOG['lock']:
            hit = _CATALOG['by_code'].get(code)
        if hit:
            return hit
    else:
        for it in items:
            if it['code'] == code:
                return it
    raise PluginError('未知频道: %s' % code)


# ================================================================ 分片缓存与预取（可选代理）
class TsCache:
    def __init__(self, limit_bytes=64 * 1024 * 1024, max_item_bytes=12 * 1024 * 1024):
        self.limit = max(0, int(limit_bytes))
        self.max_item_bytes = min(self.limit, int(max_item_bytes)) if self.limit else 0
        self.data = collections.OrderedDict()
        self.size = 0
        self.hits = 0
        self.misses = 0
        self.lock = threading.Lock()
        self.inflight = {}

    def has(self, key):
        with self.lock:
            return key in self.data

    def put(self, key, blob):
        if not isinstance(blob, bytes):
            blob = bytes(blob)
        if not blob or len(blob) > self.max_item_bytes:
            return
        with self.lock:
            prev = self.data.pop(key, None)
            if prev is not None:
                self.size -= len(prev)
            self.data[key] = blob
            self.size += len(blob)
            while self.size > self.limit and self.data:
                _, old = self.data.popitem(last=False)
                self.size -= len(old)

    def get_or_load(self, key, loader, timeout=20.0):
        with self.lock:
            blob = self.data.get(key)
            if blob is not None:
                self.hits += 1
                self.data.move_to_end(key)
                return blob
            self.misses += 1
            fut = self.inflight.get(key)
            owner = fut is None
            if owner:
                fut = Future()
                self.inflight[key] = fut
        if not owner:
            try:
                return fut.result(timeout=timeout)
            except FutureTimeout as e:
                raise PluginError('等待并发分片超时') from e
        try:
            blob = loader()
            if not blob:
                raise PluginError('空分片')
            self.put(key, blob)
            fut.set_result(blob)
            return blob
        except BaseException as e:
            fut.set_exception(e)
            raise
        finally:
            with self.lock:
                if self.inflight.get(key) is fut:
                    self.inflight.pop(key, None)

    def try_claim_stream(self, key):
        with self.lock:
            blob = self.data.get(key)
            if blob is not None:
                self.hits += 1
                self.data.move_to_end(key)
                return blob, False, None
            self.misses += 1
            fut = self.inflight.get(key)
            if fut is None:
                fut = Future()
                self.inflight[key] = fut
                return None, True, fut
            return None, False, fut

    def finish_stream(self, key, fut, blob=None, exc=None):
        try:
            if exc is not None:
                fut.set_exception(exc)
            else:
                if blob:
                    self.put(key, blob)
                fut.set_result(blob or b'')
        finally:
            with self.lock:
                if self.inflight.get(key) is fut:
                    self.inflight.pop(key, None)

    def stats(self):
        with self.lock:
            total = self.hits + self.misses
            return {
                'entries': len(self.data),
                'mb': round(self.size / 1048576.0, 2),
                'hits': self.hits,
                'misses': self.misses,
                'inflight': len(self.inflight),
                'hit_rate': ('%.1f%%' % (100.0 * self.hits / total)) if total else '-',
            }


_TS_CACHE = TsCache(int(os.environ.get('CBOX_CACHE_MB', '64')) * 1024 * 1024)
_NEXT_SEG_MAP = collections.OrderedDict()
_NEXT_SEG_LOCK = threading.Lock()


def b64u(s):
    return base64.urlsafe_b64encode(s.encode('utf-8')).decode('ascii').rstrip('=')


def unb64u(s):
    return base64.urlsafe_b64decode(s + '=' * (-len(s) % 4)).decode('utf-8')


def proxy_target_allowed(url):
    """SSRF 防护：拒绝内网/环回 IP，仅允许 http/https 标准端口。"""
    try:
        p = urllib.parse.urlsplit(url)
        host = (p.hostname or '').lower().rstrip('.')
        if p.scheme not in ('http', 'https') or not host or p.username or p.password:
            return False
        if host in ('localhost', 'ip6-localhost', 'ip6-loopback'):
            return False
        try:
            ip = ipaddress.ip_address(host)
            if ip.is_private or ip.is_loopback or ip.is_link_local or ip.is_multicast or ip.is_reserved:
                return False
        except ValueError:
            pass
        port = p.port or (443 if p.scheme == 'https' else 80)
        return port in (80, 443, 8080, 8088)
    except Exception:
        return False


def _record_and_prefetch(seg_urls, do_prefetch=False):
    if not seg_urls:
        return
    with _NEXT_SEG_LOCK:
        for i in range(len(seg_urls) - 1):
            _NEXT_SEG_MAP[seg_urls[i]] = seg_urls[i + 1]
            _NEXT_SEG_MAP.move_to_end(seg_urls[i])
        while len(_NEXT_SEG_MAP) > 1000:
            _NEXT_SEG_MAP.popitem(last=False)
    if do_prefetch:
        for u in seg_urls[-1:]:
            if not _TS_CACHE.has(u) and proxy_target_allowed(u):
                try:
                    _BG_POOL.submit(_prefetch_one, u)
                except RuntimeError:
                    pass


def _prefetch_one(url):
    try:
        _TS_CACHE.get_or_load(url, lambda: _get(url, timeout=10.0), timeout=12.0)
    except Exception:
        pass


# ================================================================ 明文线路探测与实时窗口刷新
_ROUTE_CACHE = {}
_ROUTE_LOCK = threading.Lock()
_CODE_LOCKS = {}
ROUTE_VERIFY_TTL = 1800.0   # 已验证子清单路由缓存 30 分钟
PLAYLIST_WINDOW_TTL = 2.0   # 直播分片窗口实时刷新间隔


def _parse_target_interval(text):
    m = re.search(r'#EXT-X-TARGETDURATION:(\d+)', text or '')
    if not m:
        return PLAYLIST_WINDOW_TTL
    return max(1.5, min(int(m.group(1)) * 0.5, 4.0))


def _format_playlist(txt, base_url, proxy_origin='', code='', token=''):
    out = []
    abs_segs = []
    tok_q = ('&token=' + urllib.parse.quote(token)) if token else ''
    for line in txt.splitlines():
        st = line.strip()
        if st and not st.startswith('#'):
            abs_u = urllib.parse.urljoin(base_url, st)
            abs_segs.append(abs_u)
            if proxy_origin:
                out.append('%s/proxy?u=%s&c=%s%s' % (proxy_origin, b64u(abs_u), code, tok_q))
            else:
                out.append(abs_u)
        else:
            out.append(line)
    _record_and_prefetch(abs_segs, do_prefetch=bool(proxy_origin))
    return '\n'.join(out)


def _probe_single_candidate(base, timeout=8.0, deep=True):
    """探测单条候选 URL，返回 (raw_sub_text, final_sub_url, base)。"""
    txt, cur = _fetch_text(base, timeout=timeout)
    for _lvl in range(3):
        if '#EXT-X-KEY' in txt:
            raise PluginError('加密线路')
        segs = [l.strip() for l in txt.splitlines() if l.strip() and not l.strip().startswith('#')]
        if not segs:
            raise PluginError('空清单')
        nxt = urllib.parse.urljoin(cur, segs[0])
        if '.m3u8' in nxt.split('?')[0].lower():
            txt, cur = _fetch_text(nxt, timeout=timeout)
            continue
        if deep:
            head = _get(nxt, timeout=min(timeout, 6.0), headers={'Range': 'bytes=0-187'}, max_bytes=188)
            if not head or head[:1] != b'\x47':
                raise PluginError('分片非明文 TS')
        break
    return txt, cur, base


def resolve_plain(code, timeout=8.0, deep=False, proxy_origin='', token=''):
    """找出真正可播的明文线路并返回最新直播窗口 (清单文本, 使用的子清单基地址)。"""
    if not _POLICY.get('conf') and not _CATALOG.get('cands_map'):
        load_catalog(non_blocking=True)

    now = time.time()
    with _ROUTE_LOCK:
        entry = _ROUTE_CACHE.get(code)
        ch_lock = _CODE_LOCKS.setdefault(code, threading.Lock())

    if entry and now - entry['verified_at'] < ROUTE_VERIFY_TTL:
        age = now - entry['pl_at']
        if age < entry['interval']:
            return _format_playlist(entry['pl_text'], entry['sub_url'], proxy_origin, code, token), entry['sub_url']
        if age < 12.0 and not entry['inflight']:
            try:
                txt, final_cur = _fetch_text(entry['sub_url'], timeout=min(timeout, 4.0))
                if '#EXTM3U' in txt and '#EXT-X-KEY' not in txt:
                    with _ROUTE_LOCK:
                        entry['sub_url'] = final_cur
                        entry['pl_text'] = txt
                        entry['pl_at'] = time.time()
                        entry['interval'] = _parse_target_interval(txt)
                    return _format_playlist(txt, final_cur, proxy_origin, code, token), final_cur
            except Exception:
                pass

    with ch_lock:
        now = time.time()
        with _ROUTE_LOCK:
            entry = _ROUTE_CACHE.get(code)
        if entry and now - entry['verified_at'] < ROUTE_VERIFY_TTL:
            try:
                txt, final_cur = _fetch_text(entry['sub_url'], timeout=min(timeout, 5.0))
                if '#EXTM3U' in txt and '#EXT-X-KEY' not in txt:
                    with _ROUTE_LOCK:
                        entry['sub_url'] = final_cur
                        entry['pl_text'] = txt
                        entry['pl_at'] = time.time()
                        entry['interval'] = _parse_target_interval(txt)
                    return _format_playlist(txt, final_cur, proxy_origin, code, token), final_cur
            except Exception:
                with _ROUTE_LOCK:
                    _ROUTE_CACHE.pop(code, None)

        cands = candidate_urls(code)
        if not cands:
            raise PluginError('未知或无候选线路: %s' % code)

        if entry and entry.get('cand_base') in cands:
            pref = entry['cand_base']
            cands = [pref] + [u for u in cands if u != pref]

        last_err = ''
        batch_size = 2
        for idx in range(0, len(cands), batch_size):
            batch = cands[idx:idx + batch_size]
            if len(batch) == 1:
                try:
                    txt, cur, base = _probe_single_candidate(batch[0], timeout=timeout, deep=deep)
                    now_ok = time.time()
                    with _ROUTE_LOCK:
                        _ROUTE_CACHE[code] = {
                            'sub_url': cur, 'cand_base': base,
                            'verified_at': now_ok, 'pl_at': now_ok,
                            'pl_text': txt, 'interval': _parse_target_interval(txt),
                            'inflight': False,
                        }
                    return _format_playlist(txt, cur, proxy_origin, code, token), cur
                except Exception as e:  # noqa: BLE001
                    last_err = str(e)
                    continue

            futs = {_BG_POOL.submit(_probe_single_candidate, b, timeout, deep): b for b in batch}
            winner = None
            for fut in as_completed(futs):
                try:
                    winner = fut.result()
                    break
                except Exception as e:  # noqa: BLE001
                    last_err = str(e)
            for fut in futs:
                if not fut.done():
                    fut.cancel()
            if winner is not None:
                txt, cur, base = winner
                now_ok = time.time()
                with _ROUTE_LOCK:
                    _ROUTE_CACHE[code] = {
                        'sub_url': cur, 'cand_base': base,
                        'verified_at': now_ok, 'pl_at': now_ok,
                        'pl_text': txt, 'interval': _parse_target_interval(txt),
                        'inflight': False,
                    }
                return _format_playlist(txt, cur, proxy_origin, code, token), cur

        raise PluginError('无可用明文线路（%s）' % (last_err[:50] or '未知'))


def playlist_of(code, timeout=12.0):
    """返回该频道的明文清单文本；优先通过 resolve_plain 获取真实可播子清单。"""
    txt, _ = resolve_plain(code, timeout=timeout, deep=False)
    return txt


def probe_all(jobs=16, timeout=8.0):
    """并发探测所有频道，返回可用 code 列表。"""
    items = load_catalog()

    def ok(it):
        try:
            resolve_plain(it['code'], timeout=timeout, deep=False)
            return it['code'], True
        except Exception:  # noqa: BLE001
            return it['code'], False

    good = []
    with ThreadPoolExecutor(max_workers=max(1, jobs)) as ex:
        for code, is_ok in ex.map(ok, items):
            if is_ok:
                good.append(code)
    return good


# ================================================================ EPG 节目单
_EPG_CACHE = {'ts': 0.0, 'body': b'', 'lock': threading.Lock()}


def _xml_escape(t):
    return (t or '').replace('&', '&amp;').replace('<', '&lt;').replace('>', '&gt;')


def _xml_time(ts):
    return time.strftime('%Y%m%d%H%M%S +0800', time.localtime(ts))


def _fetch_cntv_epg_one(code, date_str):
    url = '%s?c=%s&serviceId=tvcctv&d=%s&t=json' % (CNTV_EPG, urllib.parse.quote(code), date_str)
    try:
        raw = _get(url, timeout=8.0)
        data = json.loads(raw.decode('utf-8', 'replace')).get('data') or {}
        items = (data.get(code) or {}).get('list') or []
        out = []
        for it in items:
            try:
                out.append((int(it['startTime']), int(it['endTime']), it.get('title') or ''))
            except (KeyError, ValueError, TypeError):
                continue
        return code, out
    except Exception:
        return code, []


def epg_xml():
    with _EPG_CACHE['lock']:
        if _EPG_CACHE['body'] and time.time() - _EPG_CACHE['ts'] < 1800:
            return _EPG_CACHE['body']

    items = visible_items()
    parts = [
        '<?xml version="1.0" encoding="UTF-8"?>',
        '<tv generator-info-name="cbox-live-plugin %s">' % __version__,
    ]
    epg_candidates = []
    for it in items:
        cid = _xml_escape(it['code'])
        nm = _xml_escape(it['name'])
        parts.append('<channel id="%s"><display-name>%s</display-name><display-name>%s</display-name></channel>'
                     % (cid, nm, cid))
        if it['group'] in ('ldncctv', 'ldcctv', 'ldocctv', 'wstv', 'cetv', 'sports'):
            epg_candidates.append(it['code'])

    today = time.strftime('%Y%m%d')
    with ThreadPoolExecutor(max_workers=2) as pool:
        futs = [pool.submit(_fetch_cntv_epg_one, c, today) for c in epg_candidates]
        for fut in as_completed(futs):
            code, progs = fut.result()
            if not progs:
                continue
            esc_code = _xml_escape(code)
            for st, et, title in progs:
                parts.append(
                    '<programme start="%s" stop="%s" channel="%s">'
                    '<title lang="zh">%s</title></programme>'
                    % (_xml_time(st), _xml_time(et), esc_code, _xml_escape(title))
                )
    parts.append('</tv>')
    body = '\n'.join(parts).encode('utf-8')
    with _EPG_CACHE['lock']:
        _EPG_CACHE['body'] = body
        _EPG_CACHE['ts'] = time.time()
    return body


def m3u(origin, items, group=None, proxy_ts=False, token=''):
    tok_q = ('?token=' + urllib.parse.quote(token)) if token else ''
    lines = ['#EXTM3U x-tvg-url="%s/epg.xml%s" url-tvg="%s/epg.xml%s"' % (origin, tok_q, origin, tok_q)]
    for it in items:
        if group and it['group'] != group:
            continue
        logo_attr = (' tvg-logo="%s"' % it['logo']) if it.get('logo') else ''
        lines.append('#EXTINF:-1 tvg-id="%s" tvg-name="%s"%s group-title="%s",%s'
                     % (it['code'], it['name'], logo_attr,
                        GROUP_LABEL.get(it['group'], it['group']), it['name']))
        q_parts = []
        if proxy_ts:
            q_parts.append('proxy=1')
        if token:
            q_parts.append('token=' + urllib.parse.quote(token))
        qs_str = ('?' + '&'.join(q_parts)) if q_parts else ''
        lines.append('%s/live/%s.m3u8%s' % (origin, it['code'], qs_str))
    return '\n'.join(lines) + '\n'


# ================================================================ HTTP 服务
class QuietThreadingHTTPServer(ThreadingHTTPServer):
    allow_reuse_address = True
    daemon_threads = True
    request_queue_size = 64

    def __init__(self, server_address, RequestHandlerClass, max_conns=MAX_CONCURRENT_CONNS):
        self._sem = threading.BoundedSemaphore(max(8, int(max_conns)))
        super().__init__(server_address, RequestHandlerClass)

    def process_request_thread(self, request, client_address):
        try:
            super().process_request_thread(request, client_address)
        finally:
            self._sem.release()

    def process_request(self, request, client_address):
        if not self._sem.acquire(timeout=2.0):
            try:
                request.close()
            except Exception:
                pass
            return
        try:
            super().process_request(request, client_address)
        except Exception:
            self._sem.release()
            raise

    def handle_error(self, request, client_address):
        exc = sys.exc_info()[1]
        if isinstance(exc, (BrokenPipeError, ConnectionResetError, ConnectionAbortedError, socket.timeout)):
            return
        super().handle_error(request, client_address)


class Handler(BaseHTTPRequestHandler):
    server_version = 'cbox-live/' + __version__
    protocol_version = 'HTTP/1.1'

    def setup(self):
        super().setup()
        try:
            self.connection.settimeout(20.0)
        except Exception:
            pass

    def log_message(self, fmt, *args):
        if not QUIET and not self.path.startswith('/proxy'):
            log(fmt % args)

    def _origin(self):
        if ORIGIN:
            return ORIGIN.rstrip('/')
        host = self.headers.get('Host')
        if host:
            return 'http://%s' % host
        return 'http://127.0.0.1:%d' % PORT

    def _check_auth(self, qs):
        if not AUTH_TOKEN:
            return True
        got = (qs.get('token', [''])[0] or self.headers.get('X-CBox-Token', '')).strip()
        return secrets.compare_digest(got, AUTH_TOKEN)

    def _send(self, code, body=b'', ctype='text/plain; charset=utf-8', extra=None, head_only=False):
        if isinstance(body, str):
            body = body.encode('utf-8')
        try:
            self.send_response(code)
            self.send_header('Content-Type', ctype)
            self.send_header('Content-Length', str(len(body)))
            self.send_header('Access-Control-Allow-Origin', '*')
            for k, v in (extra or {}).items():
                self.send_header(k, v)
            self.end_headers()
            if body and not head_only:
                self.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError, ConnectionAbortedError, socket.timeout):
            pass

    def do_HEAD(self):
        self.do_GET(head_only=True)

    def do_GET(self, head_only=False):
        p = urllib.parse.urlsplit(self.path)
        path = p.path.rstrip('/') or '/'
        qs = urllib.parse.parse_qs(p.query)
        try:
            if path in ('/', '/index.html'):
                return self._send(200, self._index(), 'text/html; charset=utf-8', head_only=head_only)

            if path == '/health':
                with _CATALOG['lock']:
                    cat_cnt = len(_CATALOG['items'])
                avail_cnt = len(load_avail())
                with _ROUTE_LOCK:
                    warm_routes = len(_ROUTE_CACHE)
                body = json.dumps({
                    'ok': True,
                    'version': __version__,
                    'uptime_sec': int(time.time() - START_TIME),
                    'channels': avail_cnt or cat_cnt or len(AVAILABLE_BUILTIN),
                    'catalog': cat_cnt,
                    'filtered': bool(avail_cnt),
                    'warm_routes': warm_routes,
                    'http_pool': _HTTP_POOL.stats(),
                    'ts_cache': _TS_CACHE.stats(),
                    'proxy_ts_default': PROXY_TS_DEFAULT,
                }, ensure_ascii=False, indent=2)
                return self._send(200, body, 'application/json; charset=utf-8', head_only=head_only)

            if path == '/diag':
                return self._send(200, self._diag(), 'text/plain; charset=utf-8', head_only=head_only)

            if path == '/logs':
                with _LOG_LOCK:
                    lines = list(_LOG_RING)[-80:]
                return self._send(200, '\n'.join(lines) + '\n', head_only=head_only)

            if not self._check_auth(qs):
                return self._send(401, 'unauthorized\n', head_only=head_only)

            if path in ('/all.m3u', '/all.m3u8', '/m3u', '/playlist.m3u', '/cbox.m3u'):
                origin = self._origin()
                group = (qs.get('group') or [None])[0]
                use_proxy = PROXY_TS_DEFAULT or (qs.get('proxy', [''])[0] == '1')
                body = m3u(origin, visible_items(), group, proxy_ts=use_proxy, token=AUTH_TOKEN)
                return self._send(200, body, 'application/vnd.apple.mpegurl; charset=utf-8', head_only=head_only)

            if path == '/epg.xml':
                return self._send(200, epg_xml(), 'application/xml; charset=utf-8', head_only=head_only)

            if path.startswith('/live/'):
                name = path[len('/live/'):]
                code = name[:-5] if name.endswith('.m3u8') else name
                use_proxy = PROXY_TS_DEFAULT or (qs.get('proxy', [''])[0] == '1')
                if qs.get('direct', [''])[0] == '1':
                    use_proxy = False
                proxy_origin = self._origin() if use_proxy else ''
                try:
                    txt, sub_url = resolve_plain(code, proxy_origin=proxy_origin, token=AUTH_TOKEN)
                except PluginError as e:
                    return self._send(404, str(e) + '\n', head_only=head_only)
                if qs.get('direct', [''])[0] == '1':
                    self.send_response(302)
                    self.send_header('Location', sub_url)
                    self.send_header('Content-Length', '0')
                    self.send_header('Access-Control-Allow-Origin', '*')
                    self.end_headers()
                    return
                return self._send(200, txt + '\n', 'application/vnd.apple.mpegurl; charset=utf-8',
                                  {'Cache-Control': 'no-store'}, head_only=head_only)

            if path == '/proxy':
                return self._handle_proxy(qs, head_only=head_only)

            return self._send(404, b'not found\n', head_only=head_only)
        except PluginError as e:
            return self._send(502, str(e), head_only=head_only)
        except Exception as e:  # noqa: BLE001
            log('500 %s' % e)
            return self._send(500, '内部错误: %s' % e, head_only=head_only)

    def _handle_proxy(self, qs, head_only=False):
        token = (qs.get('u') or [''])[0]
        if not token:
            return self._send(400, 'missing u\n', head_only=head_only)
        try:
            url = unb64u(token)
        except Exception:
            return self._send(400, 'bad u\n', head_only=head_only)
        if not proxy_target_allowed(url):
            return self._send(403, 'proxy target not allowed\n', head_only=head_only)

        with _NEXT_SEG_LOCK:
            nxt = _NEXT_SEG_MAP.get(url)
        if nxt and not head_only:
            _record_and_prefetch([nxt], do_prefetch=True)

        ctype = 'application/vnd.apple.mpegurl' if url.split('?')[0].endswith('.m3u8') else 'video/mp2t'
        if head_only:
            blob = _TS_CACHE.get_or_load(url, lambda: _get(url, timeout=15.0), timeout=20.0)
            return self._send(200, blob, ctype, head_only=True)

        blob, is_owner, fut = _TS_CACHE.try_claim_stream(url)
        if blob is not None:
            return self._send(200, blob, ctype)
        if not is_owner:
            blob = fut.result(timeout=20.0)
            return self._send(200, blob, ctype)

        resp = None
        release_fn = None
        buf = bytearray()
        client_alive = True
        try:
            resp, _, cl, release_fn = _HTTP_POOL.request(url, timeout=15.0, stream=True)
            self.send_response(200)
            self.send_header('Content-Type', ctype)
            if cl is not None:
                self.send_header('Content-Length', str(cl))
            else:
                self.send_header('Connection', 'close')
                self.close_connection = True
            self.send_header('Access-Control-Allow-Origin', '*')
            self.end_headers()
            cur_thread = threading.current_thread()
            prev_stream_flag = getattr(cur_thread, '_host_media_stream_read', False)
            cur_thread._host_media_stream_read = True
            try:
                while True:
                    chunk = resp.read(65536)
                    if not chunk:
                        break
                    if len(buf) + len(chunk) <= _TS_CACHE.max_item_bytes:
                        buf.extend(chunk)
                    if client_alive:
                        try:
                            self.wfile.write(chunk)
                        except (BrokenPipeError, ConnectionResetError, ConnectionAbortedError, socket.timeout):
                            client_alive = False
            finally:
                cur_thread._host_media_stream_read = prev_stream_flag
            data = bytes(buf)
            if release_fn:
                release_fn(ok=True)
            _TS_CACHE.finish_stream(url, fut, blob=data)
        except BaseException as e:
            if release_fn:
                release_fn(ok=False)
            if not isinstance(e, PluginError):
                e = PluginError(str(e))
            _TS_CACHE.finish_stream(url, fut, exc=e)
            if client_alive:
                raise e

    def _diag(self):
        now = time.time()
        ps = _HTTP_POOL.stats()
        cs = _TS_CACHE.stats()
        out = [
            '=' * 56,
            'cbox-live %s 诊断报告（运行 %ds）' % (__version__, int(now - START_TIME)),
            '=' * 56,
            'HTTP 连接池: 空闲=%d 复用=%d 新建=%d' % (ps['idle'], ps['reused'], ps['created']),
            'TS 分片缓存: 条目=%d 占用=%sMB 命中=%d 未中=%d 命中率=%s'
            % (cs['entries'], cs['mb'], cs['hits'], cs['misses'], cs['hit_rate']),
            '--- 已验证活跃线路 (%d) ---' % len(_ROUTE_CACHE),
        ]
        with _ROUTE_LOCK:
            for code, r in list(_ROUTE_CACHE.items())[:50]:
                out.append('%-14s 窗口=%ds前 路由=%ds前 %s' % (
                    code, int(now - r['pl_at']), int(now - r['verified_at']), r['sub_url'][:70]))
        return '\n'.join(out) + '\n'

    def _index(self):
        items = visible_items()
        tok_q = ('?token=' + urllib.parse.quote(AUTH_TOKEN)) if AUTH_TOKEN else ''
        rows = ''.join('<li><a href="/live/%s.m3u8%s">%s</a> <small>%s · %s</small></li>'
                       % (it['code'], tok_q, it['name'], it['group'], it['code']) for it in items[:200])
        return ('<!doctype html><meta charset="utf-8"><title>央视影音直播</title>'
                '<h1>央视影音免 DRM 直播 v%s</h1><p>共 %d 路 · '
                '<a href="/all.m3u%s">/all.m3u</a> · <a href="/epg.xml%s">/epg.xml</a> · '
                '<a href="/health">/health</a> · <a href="/diag">/diag</a></p><ul>%s</ul>'
                % (__version__, len(items), tok_q, tok_q, rows))


def stop_server():
    """CCTVHost 沙箱协作式停止钩子：立即中断后台任务、释放连接池并关闭 HTTP Server。"""
    _STOP_EVENT.set()
    _BG_POOL.shutdown(wait=False, cancel_futures=True)
    with _ACTIVE_SERVERS_LOCK:
        servers = list(_ACTIVE_SERVERS)
        _ACTIVE_SERVERS.clear()
    for srv in servers:
        if getattr(srv, '_host_owner', None) is not None:
            continue
        try:
            srv.shutdown()
        except Exception:
            pass
        try:
            srv.server_close()
        except Exception:
            pass
    try:
        _HTTP_POOL.close_all()
    except Exception:
        pass


_builtins._cctvhost_stop_service = stop_server
_builtins._ysp_stop_server = stop_server


def _warmup_catalog():
    if _STOP_EVENT.wait(0.2):
        return
    try:
        load_catalog(non_blocking=True)
    except Exception:
        pass


def serve(port, bind):
    _STOP_EVENT.clear()
    _builtins._cctvhost_stop_service = stop_server
    _builtins._ysp_stop_server = stop_server
    with _CATALOG['lock']:
        if not _CATALOG['items']:
            b_items, b_by_code, b_cands = _build_builtin_catalog()
            _CATALOG['items'] = b_items
            _CATALOG['by_code'] = b_by_code
            _CATALOG['cands_map'] = b_cands
    httpd = QuietThreadingHTTPServer((bind, port), Handler)
    httpd.daemon_threads = True
    with _ACTIVE_SERVERS_LOCK:
        _ACTIVE_SERVERS.append(httpd)
    log('v%s 已启动 http://%s:%d/all.m3u（代理分片=%s）'
        % (__version__, bind, port, PROXY_TS_DEFAULT))
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        with _ACTIVE_SERVERS_LOCK:
            if httpd in _ACTIVE_SERVERS:
                _ACTIVE_SERVERS.remove(httpd)
        try:
            httpd.server_close()
        except Exception:
            pass
        _BG_POOL.shutdown(wait=False, cancel_futures=True)
        _HTTP_POOL.close_all()


def main(argv=None):
    ap = argparse.ArgumentParser(description='央视影音免 DRM 直播插件 v%s' % __version__)
    ap.add_argument('port', nargs='?', type=int, default=None)
    ap.add_argument('--port', dest='port_opt', type=int, default=None)
    ap.add_argument('--bind', default=os.environ.get('CBOX_BIND', '127.0.0.1'))
    ap.add_argument('--lan', action='store_true', help='绑定 0.0.0.0')
    ap.add_argument('--proxy-ts', action='store_true', help='将 TS 分片改写为本机 /proxy 流式代理与预取')
    ap.add_argument('--data-dir', default='', help='持久化数据目录（兼容 CCTVHost）')
    ap.add_argument('--cache-mb', type=int, default=None, help='TS 分片内存缓存上限 MB')
    ap.add_argument('--no-engine', action='store_true', help='兼容宿主启动参数')
    ap.add_argument('--no-4k', action='store_true', help='兼容宿主启动参数')
    ap.add_argument('--links-per-device', type=int, default=4, help='兼容宿主启动参数')
    ap.add_argument('--zap-debounce', type=float, default=1.2, help='兼容宿主启动参数')
    ap.add_argument('--stable-playback', action='store_true', help='兼容宿主启动参数')
    ap.add_argument('--token', default='', help='可选访问鉴权 Token')
    ap.add_argument('--list', action='store_true')
    ap.add_argument('--groups', action='store_true')
    ap.add_argument('--url', metavar='CODE')
    ap.add_argument('--check', metavar='N', type=int)
    ap.add_argument('--probe', action='store_true', help='探测全部频道（含 DRM 分组的明文线路）')
    ap.add_argument('--jobs', type=int, default=16)
    ap.add_argument('--group', metavar='NAME')
    ap.add_argument('--m3u', metavar='FILE')
    ap.add_argument('--serve', action='store_true')
    ap.add_argument('-q', '--quiet', action='store_true')
    args, _unknown = ap.parse_known_args(argv)

    global QUIET, PORT, PROXY_TS_DEFAULT, AUTH_TOKEN, BASE_DIR, AVAIL_JSON, _TS_CACHE
    QUIET = args.quiet
    PORT = args.port_opt or args.port or _detect_default_port()
    if args.proxy_ts:
        PROXY_TS_DEFAULT = True
    if args.token:
        AUTH_TOKEN = args.token.strip()
    if args.data_dir or os.environ.get('CCTVHOST_DATA_DIR'):
        BASE_DIR = _resolve_data_dir(args.data_dir)
        AVAIL_JSON = os.path.join(BASE_DIR, 'cbox-available.json')
    if args.cache_mb is not None:
        _TS_CACHE = TsCache(max(0, int(args.cache_mb)) * 1024 * 1024)
    if args.lan and args.bind in ('127.0.0.1', 'localhost', ''):
        args.bind = '0.0.0.0'
    if not QUIET:
        log('监听端口 %d（绑定 %s）' % (PORT, args.bind))

    if args.groups:
        items = load_catalog()
        cnt = {}
        for it in items:
            cnt[it['group']] = cnt.get(it['group'], 0) + 1
        for g in sorted(cnt, key=lambda x: -cnt[x]):
            print('%-12s %-10s %d 路' % (g, GROUP_LABEL.get(g, ''), cnt[g]))
        print('合计 %d 路明文频道' % len(items))
        return 0

    if args.list:
        for it in load_catalog():
            print('%-16s %-14s %-10s %s' % (it['code'], it['name'], it['group'], it['url'][:70]))
        return 0

    if args.url:
        print(by_code(args.url)['url'])
        return 0

    if args.probe:
        t0 = time.time()
        good = probe_all(args.jobs)
        save_avail(good)
        total = len(load_catalog())
        log('探测完成：%d/%d 可用，耗时 %.1fs → %s' % (len(good), total, time.time() - t0, AVAIL_JSON))
        print('可用 %d / %d' % (len(good), total))
        return 0

    if args.check:
        items = load_catalog()
        sample = items if args.check >= len(items) else items[:args.check]
        bad = 0
        for it in sample:
            try:
                pl = playlist_of(it['code'])
                ok = pl.lstrip().startswith('#EXTM3U')
                note = '分片 %d' % len([l for l in pl.splitlines() if l and not l.startswith('#')])
            except Exception as e:  # noqa: BLE001
                ok, note = False, str(e)[:60]
            print('%-16s %-14s %s %s' % (it['code'], it['name'], 'OK  ' if ok else 'FAIL', note), flush=True)
            bad += 0 if ok else 1
        print('抽检 %d 路，失败 %d' % (len(sample), bad))
        return 1 if bad else 0

    if args.m3u:
        with open(args.m3u, 'w', encoding='utf-8') as f:
            f.write(m3u('http://127.0.0.1:%d' % PORT, visible_items(), args.group,
                        proxy_ts=PROXY_TS_DEFAULT, token=AUTH_TOKEN))
        print('已写入 %s' % args.m3u)
        return 0

    serve(PORT, args.bind)
    return 0


if __name__ == '__main__':
    sys.exit(main())
