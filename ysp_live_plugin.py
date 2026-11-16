#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""央视频直播源插件 v2.1.3（CCTVHost 兼容修复版）

直播源来自 央视频 iOS 3.5.6（com.cctv.yangshipin.app.iphone）IPA 内 TVKPlayer：
    cKey 签名 -> bkliveinfo.ysp.cctv.cn?cmd=2  -> 1080p HLS（免注册）
    设备注册(ytpcloudws) -> live/v1/01 -> live/v1/02 -> VDN getstream -> 高码率
    jacc.ysp.cctv.cn (JCE, cmd=25312) -> 带 PDT 的时移窗口 -> 回看

v2.1.3 CCTVHost 专项修复：
    1. 修复 ALPN 协议死锁：移除 set_alpn_protocols(['h2', 'http/1.1']) 里的 'h2'，防止服务端协商出 HTTP/2 二进制帧导致 http.client (HTTP/1.1) 挂死或 BadStatusLine
    2. 修复 CCTVHost 嵌入式 Python 证书缺失：KeepAlivePool 与 _urllib_fetch 均支持自动免校验 SSLContext 回退并提取真实状态码与 Set-Cookie
    3. 修复流式代理分支遗漏：当存在系统代理且 stream=True 时自动适配内存流，不再走错误的手动 CONNECT 隧道
    4. 修复 --lan 绑定覆盖：仅当未显式指定非回环 --bind 时才被 --lan 覆盖
    5. 保留真 Keep-Alive 连接池、64KB 边下边推流式分片、下一分片预取、有界 _SEG 防泄漏与 8 线程并发 EPG

用法:
    python3 ysp_live_plugin.py --list
    python3 ysp_live_plugin.py --url cctv1 [--high]
    python3 ysp_live_plugin.py --check all
    python3 ysp_live_plugin.py --m3u ysp.m3u
    python3 ysp_live_plugin.py --serve --port 8768

服务接口:
    /all.m3u                 订阅（含 catchup 模板 + 本地节目单）
    /live/<slug>.m3u8        直播（分片走本地缓存 + 流式转发）
    /live/<slug>.m3u8?start=&end=   JCE 时移回看
    /epg.xml                 节目单（XMLTV）
    /seg/<key>.ts            分片（TS 缓存 + 边下边推 + 预取）
    /health                  设备/缓存/连接池状态
    /diag                    完整诊断报告

环境变量: YSP_PORT、YSP_CACHE_MB、YSP_DEVICE_JSON、YSP_TOKEN
"""
from __future__ import annotations

import argparse
import base64
import binascii
import collections
from concurrent.futures import Future, ThreadPoolExecutor, TimeoutError as FutureTimeout, as_completed
import dataclasses
import functools
import gzip
import hashlib
import hmac as _hmac
import http.client
import json
import math
import os
import random
import re
import secrets
import socket
import ssl
import struct
import sys
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

__version__ = '2.2.0'


def _make_ssl_ctx(verified=True):
    try:
        ctx = ssl.create_default_context() if verified else ssl._create_unverified_context()
    except Exception:
        ctx = ssl._create_unverified_context()
    try:
        # 绝不能声明 'h2'！http.client 仅支持 HTTP/1.1，协商出 h2 会导致服务端发 HTTP/2 帧而客户端挂死
        ctx.set_alpn_protocols(['http/1.1'])
    except Exception:
        pass
    return ctx


_SSL_VERIFIED = _make_ssl_ctx(True)
_SSL_UNVERIFIED = _make_ssl_ctx(False)
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


class _SocketTrackingMixin:
    """http.client 连接混入：在 connect() 内拦截 socket.create_connection，
    使 socket 在进入（可能长时间阻塞的）代理 CONNECT / TLS 握手前就已登记，
    stop 时可立即 shutdown 中断。不重写任何握手逻辑，行为与基类完全一致。"""

    def connect(self):
        orig_create = socket.create_connection

        def _creating(address, timeout=None, source_address=None):
            sock = orig_create(address, timeout=timeout, source_address=source_address)
            _register_socket(sock)
            return sock

        socket.create_connection = _creating
        try:
            super().connect()
        finally:
            socket.create_connection = orig_create

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


def _urllib_fetch(method, url, headers=None, data=None, timeout=15.0, cookies=None):
    """Fetch via urllib (honors proxy env vars + unverified SSL fallback).

    Returns (status, reason, resp_hdrs, body, final_url).
    """
    global _GLOBAL_INSECURE_TLS
    hdrs = {}
    for k, v in (headers or {}).items():
        if v is not None:
            hdrs[k] = str(v)
    if cookies:
        ck_str = '; '.join('%s=%s' % (k, v) for k, v in cookies.items())
        if ck_str:
            hdrs['Cookie'] = ck_str
    req = urllib.request.Request(url, headers=hdrs, data=data, method=method.upper())

    for attempt in (0, 1):
        ctx = _SSL_UNVERIFIED if (_GLOBAL_INSECURE_TLS or attempt == 1) else _SSL_VERIFIED
        try:
            opener = urllib.request.build_opener(
                _TrackedHTTPHandler(), _TrackedHTTPSHandler(context=ctx),
                urllib.request.ProxyHandler(),
            )
            with opener.open(req, timeout=timeout) as resp:
                status = getattr(resp, 'status', 200) or 200
                reason = getattr(resp, 'reason', 'OK') or 'OK'
                resp_hdrs = {k.lower(): v for k, v in resp.headers.items()} if resp.headers else {}
                if cookies is not None and resp.headers:
                    for k, v in resp.headers.items():
                        if k.lower() == 'set-cookie':
                            m = re.match(r'\s*([^=;,\s]+)=([^;,\r\n]*)', v)
                            if m:
                                cookies[m.group(1)] = m.group(2)
                body = _read_body_chunked(resp)
                ce = resp_hdrs.get('content-encoding', '').lower()
                if 'gzip' in ce or body[:2] == b'\x1f\x8b':
                    try:
                        body = gzip.decompress(body)
                    except Exception:
                        pass
                return status, reason, resp_hdrs, body, resp.geturl()
        except urllib.error.HTTPError as e:
            status = e.code
            reason = e.reason or ''
            resp_hdrs = {k.lower(): v for k, v in e.headers.items()} if e.headers else {}
            try:
                body = _read_body_chunked(e.fp) if e.fp is not None else b''
            except Exception:
                body = b''
            return status, reason, resp_hdrs, body, url
        except Exception as e:
            if attempt == 0 and ('CERTIFICATE_VERIFY_FAILED' in str(e) or isinstance(e, ssl.SSLError)):
                _GLOBAL_INSECURE_TLS = True
                continue
            raise YsptpError(_normalize_network_error(e)) from e


import builtins as _builtins


def _read_body_chunked(resp, max_bytes=16 * 1024 * 1024):
    """以 <=64KB 分块读取响应体，并标记 _host_media_stream_read 以兼容 CCTVHost 并发预算与字节限额。"""
    if resp is None:
        return b''
    t = threading.current_thread()
    prev = getattr(t, '_host_media_stream_read', False)
    t._host_media_stream_read = True
    try:
        buf = bytearray()
        while True:
            chunk = resp.read(65536)
            if not chunk:
                break
            buf.extend(chunk)
            if max_bytes and len(buf) > max_bytes:
                raise RuntimeError('HTTP 响应超出最大长度限制 (%d bytes)' % max_bytes)
        return bytes(buf)
    finally:
        t._host_media_stream_read = prev


def _detect_default_port(default=18768):
    for name in ('CCTVHOST_PORT', 'YSP_PORT', 'PORT', 'SERVER_PORT', 'MINIS_PORT', 'HTTP_PORT'):
        val = os.environ.get(name, '').strip()
        if val.isdigit():
            p = int(val)
            if 1 <= p <= 65535:
                return p
    return default


def _resolve_data_dir(explicit_dir=''):
    candidates = [
        explicit_dir,
        os.environ.get('CCTVHOST_DATA_DIR', ''),
        os.environ.get('YSP_DATA_DIR', ''),
        os.path.dirname(os.path.abspath(__file__)) if '__file__' in globals() else os.getcwd(),
    ]
    for cand in candidates:
        if cand and cand.strip():
            d = os.path.abspath(cand.strip())
            try:
                os.makedirs(d, exist_ok=True)
                return d
            except OSError:
                continue
    return os.getcwd()


DATA_DIR = _resolve_data_dir()
DEVICE_JSON = os.environ.get('YSP_DEVICE_JSON', '') or os.path.join(DATA_DIR, 'ysp-device.json')
PORT = _detect_default_port(18768)
AUTH_TOKEN = os.environ.get('YSP_TOKEN', '').strip()
PROXY_TS_DEFAULT = os.environ.get('YSP_PROXY_TS', '0').strip() in ('1', 'true', 'yes')
NO_4K_DEFAULT = os.environ.get('YSP_NO_4K', '0').strip() in ('1', 'true', 'yes')
MAX_CONCURRENT_CONNS = int(os.environ.get('YSP_MAX_CONNS', '64'))
START_TIME = time.time()
_STOP_EVENT = threading.Event()
_ACTIVE_SERVERS = []
_ACTIVE_SERVERS_LOCK = threading.Lock()

# 在途出站 socket 注册表：stop 时立即 shutdown 正在握手/读写中的
# socket，使卡在代理 CONNECT、TLS 握手或响应读取里的后台任务立刻退出，
# 而不是等到各自的网络超时。只登记本插件经 _urllib_fetch 或 KeepAlivePool
# 发起的出站连接；入站 HTTP 服务的 socket 不在此列。
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
    """按需创建后台线程池，避免空闲常驻线程阻塞 CCTVHost session.clean()，并在停止时立即回收。"""
    def __init__(self, max_workers=2):
        self._max_workers = max_workers
        self._pool = None
        self._lock = threading.Lock()

    def submit(self, fn, *args, **kwargs):
        if _STOP_EVENT.is_set():
            raise RuntimeError('service is stopping')
        with self._lock:
            if self._pool is None:
                self._pool = ThreadPoolExecutor(max_workers=self._max_workers, thread_name_prefix='ysp-bg')
            return self._pool.submit(fn, *args, **kwargs)

    def shutdown(self, wait=False, cancel_futures=True):
        with self._lock:
            pool, self._pool = self._pool, None
        if pool is not None:
            try:
                pool.shutdown(wait=wait, cancel_futures=cancel_futures)
            except TypeError:
                pool.shutdown(wait=wait)

AK = '9f5c54c4ed0e50109b800f7e28fec205'
RSA_PUBLIC_KEY_B64 = 'MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAkKeLy4ywWLSnBkwRyqYgF3HMIj05V5uuh5HjyEsZOWnu1NHu3jPQv3sr32wwQNYv5qapsNXmNgLUDHtgHZxqPQAYXltjSRc0qhcD286t62wOIHId8zXS3s1Jy4rgU4qjQWzI9rp/1sE0pMsmwTaJa4zuJ5iz8VwF8Av5oJ1k+HxY+/HLnjNlW1hmWLpuDYmkZYuAoTHa1VGeHQh9FEKI8ZcL3GTQphShUoC+Kg3P1hGUVTtCYapmzPS5lkAdwebuzwvTCfGiTErYZCnPBUSeV7BVlgjtLYIi29KvF0a8FHsJMfe/UdHcyW/RihsIYOtDQcRRpFGXyPXbVrzFJse24QIDAQAB'
CLOUD_GET_URL = 'https://ytpcloudws.cctv.cn/cloudps/wssapi/device/v2/get'
CLOUD_REGISTER_URL = 'https://ytpcloudws.cctv.cn/cloudps/wssapi/device/v2/register'
APP_START_URL = 'https://ytpaddr.cctv.cn/gsnw/api/app/start/v1/01'
DRM_CONFIG_URL = 'https://ytpaddr.cctv.cn/gsnw/drm/config/obtain/v1'
VERSION_CONFIG_URL = 'https://ytpaddr.cctv.cn/gsnw/version/config/obtain/v1'
DICTIONARY_URL = 'https://ytpaddr.cctv.cn/gsnw/player/dictionary/obtain/v1'
INDEX_URL = 'https://ytpaddr.cctv.cn/gsnw/api/index/v1/01'
REPORT_SINGLE_URL = 'https://ytpdata.cctv.cn/das/app/data/message/single'
COLLECT_REPORT_URL = 'https://collect.cctv.cn/cctvmobileinf/rest/cctv/receive/new/app'
LIVE_V1_01_URL = 'https://ytpaddr.cctv.cn/gsnw/api/live/v1/01'
LIVE_V1_02_URL = 'https://ytpaddr.cctv.cn/gsnw/api/live/v1/02'
VDN_GETSTREAM_URL = 'https://ytpvdn.cctv.cn/cctvmobileinf/rest/cctv/videoliveUrl/getstream'
DEFAULT_LIVE_USER_ID = 'BAEBFF2B-C516-4F34-ABC0-A824A6461CBD'
DEFAULT_DEVICE_NAME = '央视频电视投屏助手'
VDN_APP_NAME = '央视频电视投屏助手'
REPORT_APP_KEY = '1178c84d-4818-44ff-b415-02106e87e144'
COLLECT_SDK_VERSION = '1.0.0'
DEFAULT_PAGE_NAME = 'com.cctv.tv.mvp.ui.activity.MainActivity'
DEFAULT_ACCEPT_LANGUAGE = 'zh-CN,zh;q=0.8'
RESULT_OK = 0
RESULT_NEEDS_REGISTER = 601
RESULT_GET_MISSING_OR_INVALID = 2
RESULT_REGISTERED_ELSEWHERE = 694
RESULT_REGISTER_RETRY_LATER = 695

LOGO_BASE = 'https://app.cctv.com/special/appchannellogo/square/l'
OFFICIAL_LOGOS = {
    'cctv4k': 'https://app.cctv.com/special/appchannellogo/square/l/cctv4K.png?q=75',
    'cctv8k': 'https://app.cctv.com/special/appchannellogo/square/l/cctv8K.png?q=75',
    'cctv5p': 'https://app.cctv.com/special/appchannellogo/square/l/cctv5plus.png?q=75',
    'cctv16': 'https://p3.img.cctvpic.com/photoAlbum/page/performance/img/2021/10/22/1634889304044_685.png',
    'cctv164k': 'https://p3.img.cctvpic.com/photoAlbum/page/performance/img/2021/10/26/1635212423166_900.png',
    'cgtn': 'https://app.cctv.com/special/appchannellogo/square/l/cctv9.png?q=75',
    'bjws': 'https://p3.img.cctvpic.com/photoAlbum/page/performance/img/2026/2/5/1770272590497_949.png',
    'dfws': 'https://app.cctv.com/special/appchannellogo/square/l/dongfang.png?q=75',
    'hnws': 'https://app.cctv.com/special/appchannellogo/square/l/hunan.png?q=75',
    'zjws': 'https://app.cctv.com/special/appchannellogo/square/l/zhejiang.png?q=75',
    'jsws': 'https://app.cctv.com/special/appchannellogo/square/l/jiangsu.png?q=75',
    'gdws': 'https://app.cctv.com/special/appchannellogo/square/l/guangdong.png?q=75',
    'szws': 'https://app.cctv.com/special/appchannellogo/square/l/shenzhen.png?q=75',
    'hljws': 'https://app.cctv.com/special/appchannellogo/square/l/heilongjiang.png?q=75',
    'lnws': 'https://app.cctv.com/special/appchannellogo/square/l/liaoning.png?q=75',
    'sdws': 'https://app.cctv.com/special/appchannellogo/square/l/shandong.png?q=75',
    'ahws': 'https://app.cctv.com/special/appchannellogo/square/l/anhui.png?q=75',
    'hbws': 'https://app.cctv.com/special/appchannellogo/square/l/hubei.png?q=75',
    'scws': 'https://app.cctv.com/special/appchannellogo/square/l/sichuan.png?q=75',
    'cqws': 'https://p3.img.cctvpic.com/photoAlbum/page/performance/img/2022/4/8/1649386058290_834.png',
    'jxws': 'https://app.cctv.com/special/appchannellogo/square/l/jiangxi.png?q=75',
    'dnws': 'https://app.cctv.com/special/appchannellogo/square/l/fujian.png?q=75',
    'henanws': 'https://app.cctv.com/special/appchannellogo/square/l/henan.png?q=75',
    'hebws': 'https://app.cctv.com/special/appchannellogo/square/l/hebei.png?q=75',
    'shanxiws': 'https://app.cctv.com/special/appchannellogo/square/l/shanxi.png?q=75',
    'saxws': 'https://app.cctv.com/special/appchannellogo/square/l/shaanxi.png?q=75',
    'gsws': 'https://app.cctv.com/special/appchannellogo/square/l/gansu.png?q=75',
    'gxws': 'https://app.cctv.com/special/appchannellogo/square/l/guangxi.png?q=75',
    'gzws': 'https://app.cctv.com/special/appchannellogo/square/l/guizhou.png?q=75',
    'ynws': 'https://app.cctv.com/special/appchannellogo/square/l/yunnan.png?q=75',
    'hainanws': 'https://app.cctv.com/special/appchannellogo/square/l/travel.png?q=75',
    'jlws': 'https://app.cctv.com/special/appchannellogo/square/l/jilin.png?q=75',
    'tjws': 'https://app.cctv.com/special/appchannellogo/square/l/tianjin.png?q=75',
    'nxws': 'https://app.cctv.com/special/appchannellogo/square/l/ningxia.png?q=75',
    'nmgws': 'https://app.cctv.com/special/appchannellogo/square/l/neimenggu.png?q=75',
    'qhws': 'https://app.cctv.com/special/appchannellogo/square/l/qinghai.png?q=75',
    'xizangws': 'https://app.cctv.com/special/appchannellogo/square/l/xizang.png?q=75',
    'xjws': 'https://app.cctv.com/special/appchannellogo/square/l/xinjiang.png?q=75',
    'cetv1': 'https://app.cctv.com/special/appchannellogo/square/l/cetv1.png?q=75',
}
CANONICAL_TVG_IDS = {
    'cctv5p': 'cctv5plus',
    'cctv9': 'cctvjilu',
    'cctv14': 'cctvchild',
    'bjws': 'btv1',
    'dfws': 'dongfang',
    'hnws': 'hunan',
    'zjws': 'zhejiang',
    'jsws': 'jiangsu',
    'gdws': 'guangdong',
    'szws': 'shenzhen',
    'hljws': 'heilongjiang',
    'lnws': 'liaoning',
    'sdws': 'shandong',
    'ahws': 'anhui',
    'hbws': 'hubei',
    'scws': 'sichuan',
    'cqws': 'chongqing',
    'jxws': 'jiangxi',
    'dnws': 'fujian',
    'henanws': 'henan',
    'hebws': 'hebei',
    'shanxiws': 'shanxi',
    'saxws': 'shaanxi',
    'gsws': 'gansu',
    'gxws': 'guangxi',
    'gzws': 'guizhou',
    'ynws': 'yunnan',
    'hainanws': 'hainan',
    'jlws': 'jilin',
}


def get_channel_logo(slug):
    if slug in OFFICIAL_LOGOS:
        return OFFICIAL_LOGOS[slug]
    return '%s/%s.png?q=75' % (LOGO_BASE, slug)


def get_canonical_tvg_id(slug):
    return CANONICAL_TVG_IDS.get(slug, slug)
UA = ('Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/120.0 Safari/537.36')


DEFAULT_CHANNELS = [
    ('cctv1', 'CCTV-1 综合', '2024078201', '600001859', 'fhd'),
    ('cctv2', 'CCTV-2 财经', '2024075401', '600001800', 'fhd'),
    ('cctv3', 'CCTV-3 综艺', '2024068501', '600001801', 'fhd'),
    ('cctv4', 'CCTV-4 中文国际', '2029797101', '600001814', 'fhd'),
    ('cctv5', 'CCTV-5 体育', '2024078401', '600001818', 'fhd'),
    ('cctv5p', 'CCTV-5+ 体育赛事', '2024078001', '600001817', 'fhd'),
    ('cctv6', 'CCTV-6 电影', '2013693901', '600108442', 'fhd'),
    ('cctv7', 'CCTV-7 国防军事', '2024072001', '600004092', 'fhd'),
    ('cctv8', 'CCTV-8 电视剧', '2029793001', '600001803', 'fhd'),
    ('cctv9', 'CCTV-9 纪录', '2024078601', '600004078', 'fhd'),
    ('cctv10', 'CCTV-10 科教', '2024078701', '600001805', 'fhd'),
    ('cctv11', 'CCTV-11 戏曲', '2027248701', '600001806', 'fhd'),
    ('cctv12', 'CCTV-12 社会与法', '2027248801', '600001807', 'fhd'),
    ('cctv13', 'CCTV-13 新闻', '2029797201', '600001811', 'fhd'),
    ('cctv14', 'CCTV-14 少儿', '2027248901', '600001809', 'fhd'),
    ('cctv15', 'CCTV-15 音乐', '2027249001', '600001815', 'fhd'),
    ('cctv16', 'CCTV-16 奥林匹克', '2027249101', '600098637', 'fhd'),
    ('cctv164k', 'CCTV-16 4K', '2027249301', '600099502', 'fhd'),
    ('cctv17', 'CCTV-17 农业农村', '2027249401', '600001810', 'fhd'),
    ('cctv4k', 'CCTV-4K 超高清', '2029810301', '600002264', 'fhd'),
    ('cctv8k', 'CCTV-8K 超高清', '2026774101', '600156816', 'fhd'),
    ('cgtn', 'CGTN', '2024181701', '600014550', 'fhd'),
    ('cgtnfr', 'CGTN 法语', '2024181801', '600084704', 'fhd'),
    ('cgtnru', 'CGTN 俄语', '2024181901', '600084758', 'fhd'),
    ('cgtnar', 'CGTN 阿拉伯语', '2024182001', '600084782', 'fhd'),
    ('cgtnes', 'CGTN 西班牙语', '2024182101', '600084744', 'fhd'),
    ('cgtndoc', 'CGTN 纪录', '2024182301', '600084781', 'fhd'),
    ('cctvfyjc', 'CCTV 风云剧场', '2025637102', '600099658', 'shd'),
    ('cctvdyjc', 'CCTV 第一剧场', '2026874202', '600099655', 'shd'),
    ('cctvhjjc', 'CCTV 怀旧剧场', '2026874302', '600099620', 'shd'),
    ('bjws', '北京卫视', '2024052703', '600002309', 'fhd'),
    ('jsws', '江苏卫视', '2024171103', '600002521', 'fhd'),
    ('dfws', '东方卫视', '2024054503', '600002483', 'fhd'),
    ('zjws', '浙江卫视', '2024054703', '600002520', 'fhd'),
    ('hnws', '湖南卫视', '2024054803', '600002475', 'fhd'),
    ('hbws', '湖北卫视', '2024171203', '600002508', 'fhd'),
    ('gdws', '广东卫视', '2024060903', '600002485', 'fhd'),
    ('gxws', '广西卫视', '2024060703', '600002509', 'fhd'),
    ('hljws', '黑龙江卫视', '2029797003', '600002498', 'fhd'),
    ('hainanws', '海南卫视', '2024055603', '600002506', 'fhd'),
    ('cqws', '重庆卫视', '2024061103', '600002531', 'fhd'),
    ('szws', '深圳卫视', '2024061303', '600002481', 'fhd'),
    ('scws', '四川卫视', '2024061403', '600002516', 'fhd'),
    ('henanws', '河南卫视', '2029797303', '600002525', 'fhd'),
    ('dnws', '东南卫视', '2024061503', '600002484', 'fhd'),
    ('gzws', '贵州卫视', '2024061603', '600002490', 'fhd'),
    ('jxws', '江西卫视', '2024061703', '600002503', 'fhd'),
    ('lnws', '辽宁卫视', '2024171303', '600002505', 'fhd'),
    ('ahws', '安徽卫视', '2024171403', '600002532', 'fhd'),
    ('hebws', '河北卫视', '2024171503', '600002493', 'fhd'),
    ('sdws', '山东卫视', '2029787903', '600002513', 'fhd'),
    ('tjws', '天津卫视', '2019927003', '600152137', 'fhd'),
    ('jlws', '吉林卫视', '2025561503', '600190405', 'fhd'),
    ('saxws', '陕西卫视', '2029795103', '600190400', 'fhd'),
    ('nxws', '宁夏卫视', '2025608503', '600190737', 'fhd'),
    ('nmgws', '内蒙古卫视', '2025561203', '600190401', 'fhd'),
    ('ynws', '云南卫视', '2025561303', '600190402', 'fhd'),
    ('shanxiws', '山西卫视', '2025560803', '600190407', 'fhd'),
    ('gsws', '甘肃卫视', '2025561703', '600190408', 'fhd'),
    ('qhws', '青海卫视', '2025559103', '600190406', 'fhd'),
    ('xizangws', '西藏卫视', '2025558003', '600190403', 'fhd'),
    ('xjws', '新疆卫视', '2019927403', '600152138', 'fhd'),
    ('cetv1', 'CETV-1', '2022823801', '600171827', 'fhd'),
    ('guoxue', '国学频道', '2029360403', '600213139', 'fhd')
]
ALIAS_MAP = {
    'anhuiws': 'ahws', 'beijingws': 'bjws', 'cctv16hd': 'cctv16', 'cctv5plus': 'cctv5p',
    'cctvdiyijuchang': 'cctvdyjc', 'cctvfengyunjuchang': 'cctvfyjc', 'cctvhuaijiujuchang': 'cctvhjjc',
    'cgtnalaboyu': 'cgtnar', 'cgtneyu': 'cgtnru', 'cgtnfayu': 'cgtnfr', 'cgtnwaiyujilu': 'cgtndoc',
    'cgtnxibanyayu': 'cgtnes', 'chongqingws': 'cqws', 'dongfangws': 'dfws', 'fujiandongnanws': 'dnws',
    'guangdongws': 'gdws', 'guangxiws': 'gxws', 'guizhouws': 'gzws', 'hebeiws': 'hebws',
    'heilongjiangws': 'hljws', 'hubeiws': 'hbws', 'hunanws': 'hnws', 'jiangsuws': 'jsws',
    'jiangxiws': 'jxws', 'jilinws': 'jlws', 'liaoningws': 'lnws', 'neimengguws': 'nmgws',
    'ningxiaws': 'nxws', 'qinghaiws': 'qhws', 'shandongws': 'sdws', 'shannxiws': 'saxws',
    'shenzhenws': 'szws', 'sichuanws': 'scws', 'tianjinws': 'tjws', 'xinjiangws': 'xjws',
    'yunnanws': 'ynws', 'zhejiangws': 'zjws'
}
TVG_IDS = {
    'cctv1': 'CCTV1', 'cctv2': 'CCTV2', 'cctv3': 'CCTV3', 'cctv4': 'CCTV4',
    'cctv5': 'CCTV5', 'cctv5p': 'CCTV5+', 'cctv6': 'CCTV6', 'cctv7': 'CCTV7',
    'cctv8': 'CCTV8', 'cctv9': 'CCTV9', 'cctv10': 'CCTV10', 'cctv11': 'CCTV11',
    'cctv12': 'CCTV12', 'cctv13': 'CCTV13', 'cctv14': 'CCTV14', 'cctv15': 'CCTV15',
    'cctv16': 'CCTV16', 'cctv164k': 'CCTV16', 'cctv17': 'CCTV17', 'cctv4k': 'CCTV4K',
    'cctv8k': 'CCTV-8K', 'cgtn': 'CGTN英语', 'cgtnfr': 'CGTN法语', 'cgtnru': 'CGTN俄语',
    'cgtnar': 'CGTN阿语', 'cgtnes': 'CGTN西语', 'cgtndoc': 'CGTN纪录',
    'cctvdyjc': 'CCTV第一剧场', 'cctvfyjc': 'CCTV风云剧场', 'cctvhjjc': 'CCTV怀旧剧场',
    'cetv1': 'CETV1', 'bjws': '北京卫视', 'jsws': '江苏卫视', 'dfws': '东方卫视',
    'zjws': '浙江卫视', 'hnws': '湖南卫视', 'hbws': '湖北卫视', 'gdws': '广东卫视',
    'gxws': '广西卫视', 'hljws': '黑龙江卫视', 'hainanws': '海南卫视', 'cqws': '重庆卫视',
    'szws': '深圳卫视', 'scws': '四川卫视', 'henanws': '河南卫视', 'dnws': '东南卫视',
    'gzws': '贵州卫视', 'jxws': '江西卫视', 'lnws': '辽宁卫视', 'ahws': '安徽卫视',
    'hebws': '河北卫视', 'sdws': '山东卫视', 'tjws': '天津卫视', 'jlws': '吉林卫视',
    'saxws': '陕西卫视', 'nxws': '宁夏卫视', 'nmgws': '内蒙古卫视', 'ynws': '云南卫视',
    'shanxiws': '山西卫视', 'qhws': '青海卫视', 'xizangws': '西藏卫视', 'xjws': '新疆卫视',
    'gsws': '甘肃卫视', 'guoxue': '国学'
}


def get_channel_group(slug):
    s = ALIAS_MAP.get(slug.lower(), slug.lower())
    return '央视' if (s.startswith('cctv') or s.startswith('cgtn')) else '卫视'


CHANNELS = {c[0]: {'name': c[1], 'sid': c[2], 'pid': c[3], 'defn': c[4]} for c in DEFAULT_CHANNELS}
CHANNEL_ORDER = [c[0] for c in DEFAULT_CHANNELS]

LIVE_IDS = {
    'cctv1': 'Live1717729995180256',
    'cctv2': 'Live1718261577870260',
    'cctv3': 'Live1718261955077261',
    'cctv4': 'Live1718276148119264',
    'cctv5': 'Live1719474204987287',
    'cctv5p': 'Live1719473996025286',
    'cctv7': 'Live1718276412224269',
    'cctv8': 'Live1718276458899270',
    'cctv9': 'Live1718276503187272',
    'cctv10': 'Live1718276550002273',
    'cctv11': 'Live1718276603690275',
    'cctv12': 'Live1718276623932276',
    'cctv13': 'Live1718276575708274',
    'cctv14': 'Live1718276498748271',
    'cctv15': 'Live1718276319614267',
    'cctv16': 'Live1718276256572265',
    'cctv17': 'Live1718276138318263',
    'cctv4k': 'Live1767871224782105',
    'cctv8k': 'Live1688400593818102',
    'cctv164k': 'Live1704966749996185',
    'cgtn': 'Live1719392219423280',
    'cgtnfr': 'Live1719392670442283',
    'cgtnru': 'Live1719392779653284',
    'cgtnar': 'Live1719392885692285',
    'cgtnes': 'Live1719392560433282',
    'cgtndoc': 'Live1719392360336281',
}


# ---- AES/GCM/RSA/指纹工具（轮密钥缓存加速）----
_SBOX = (99, 124, 119, 123, 242, 107, 111, 197, 48, 1, 103, 43, 254, 215, 171, 118, 202, 130, 201, 125, 250, 89, 71, 240, 173, 212, 162, 175, 156, 164, 114, 192, 183, 253, 147, 38, 54, 63, 247, 204, 52, 165, 229, 241, 113, 216, 49, 21, 4, 199, 35, 195, 24, 150, 5, 154, 7, 18, 128, 226, 235, 39, 178, 117, 9, 131, 44, 26, 27, 110, 90, 160, 82, 59, 214, 179, 41, 227, 47, 132, 83, 209, 0, 237, 32, 252, 177, 91, 106, 203, 190, 57, 74, 76, 88, 207, 208, 239, 170, 251, 67, 77, 51, 133, 69, 249, 2, 127, 80, 60, 159, 168, 81, 163, 64, 143, 146, 157, 56, 245, 188, 182, 218, 33, 16, 255, 243, 210, 205, 12, 19, 236, 95, 151, 68, 23, 196, 167, 126, 61, 100, 93, 25, 115, 96, 129, 79, 220, 34, 42, 144, 136, 70, 238, 184, 20, 222, 94, 11, 219, 224, 50, 58, 10, 73, 6, 36, 92, 194, 211, 172, 98, 145, 149, 228, 121, 231, 200, 55, 109, 141, 213, 78, 169, 108, 86, 244, 234, 101, 122, 174, 8, 186, 120, 37, 46, 28, 166, 180, 198, 232, 221, 116, 31, 75, 189, 139, 138, 112, 62, 181, 102, 72, 3, 246, 14, 97, 53, 87, 185, 134, 193, 29, 158, 225, 248, 152, 17, 105, 217, 142, 148, 155, 30, 135, 233, 206, 85, 40, 223, 140, 161, 137, 13, 191, 230, 66, 104, 65, 153, 45, 15, 176, 84, 187, 22)
_RCON = (1, 2, 4, 8, 16, 32, 64, 128, 27, 54)


def _xtime(a: int) -> int:
    return (a << 1 ^ 283) & 255 if a & 128 else a << 1 & 255


@functools.lru_cache(maxsize=64)
def _aes256_key_schedule(key: bytes):
    assert len(key) == 32
    w = [int.from_bytes(key[i:i + 4], 'big') for i in range(0, 32, 4)]
    for i in range(8, 60):
        temp = w[i - 1]
        if i % 8 == 0:
            temp = _SBOX[temp >> 16 & 255] << 24 | _SBOX[temp >> 8 & 255] << 16 | _SBOX[temp & 255] << 8 | _SBOX[temp >> 24 & 255]
            temp ^= _RCON[i // 8 - 1] << 24
        elif i % 8 == 4:
            temp = _SBOX[temp >> 24 & 255] << 24 | _SBOX[temp >> 16 & 255] << 16 | _SBOX[temp >> 8 & 255] << 8 | _SBOX[temp & 255]
        w.append(w[i - 8] ^ temp)
    return tuple(b''.join((word.to_bytes(4, 'big') for word in w[i:i + 4])) for i in range(0, 60, 4))


def _add_round_key(state, rk: bytes):
    for i in range(16):
        state[i] ^= rk[i]


def _sub_bytes(state):
    for i in range(16):
        state[i] = _SBOX[state[i]]


def _shift_rows(s):
    s[1], s[5], s[9], s[13] = (s[5], s[9], s[13], s[1])
    s[2], s[6], s[10], s[14] = (s[10], s[14], s[2], s[6])
    s[3], s[7], s[11], s[15] = (s[15], s[3], s[7], s[11])


def _mix_columns(s):
    for c in range(4):
        a0, a1, a2, a3 = (s[4 * c], s[4 * c + 1], s[4 * c + 2], s[4 * c + 3])
        s[4 * c] = _xtime(a0) ^ (_xtime(a1) ^ a1) ^ a2 ^ a3
        s[4 * c + 1] = a0 ^ _xtime(a1) ^ (_xtime(a2) ^ a2) ^ a3
        s[4 * c + 2] = a0 ^ a1 ^ _xtime(a2) ^ (_xtime(a3) ^ a3)
        s[4 * c + 3] = _xtime(a0) ^ a0 ^ a1 ^ a2 ^ _xtime(a3)


def _aes256_encrypt_block_rk(rk, block: bytes) -> bytes:
    s = bytearray(block)
    _add_round_key(s, rk[0])
    for rnd in range(1, 14):
        _sub_bytes(s)
        _shift_rows(s)
        _mix_columns(s)
        _add_round_key(s, rk[rnd])
    _sub_bytes(s)
    _shift_rows(s)
    _add_round_key(s, rk[14])
    return bytes(s)


def aes256_encrypt_block(key: bytes, block: bytes) -> bytes:
    return _aes256_encrypt_block_rk(_aes256_key_schedule(key), block)


def _gf_mult(x: int, y: int) -> int:
    r = 299076299051606071403356588563077529600
    z = 0
    v = y
    for _ in range(128):
        if x & 170141183460469231731687303715884105728:
            z ^= v
        if v & 1:
            v = v >> 1 ^ r
        else:
            v >>= 1
        x = x << 1 & 340282366920938463463374607431768211455
    return z


def _ghash(h: int, aad: bytes, ct: bytes) -> int:
    x = 0

    def _blocks(data: bytes):
        for i in range(0, len(data), 16):
            blk = data[i:i + 16]
            if len(blk) < 16:
                blk = blk + b'\x00' * (16 - len(blk))
            yield int.from_bytes(blk, 'big')

    for b in _blocks(aad):
        x = _gf_mult(x ^ b, h)
    for b in _blocks(ct):
        x = _gf_mult(x ^ b, h)
    lens = len(aad) * 8 << 64 | len(ct) * 8
    x = _gf_mult(x ^ lens, h)
    return x


def _inc32(block: bytes) -> bytes:
    ctr = int.from_bytes(block[12:], 'big')
    return block[:12] + (ctr + 1 & 4294967295).to_bytes(4, 'big')


def _gctr_rk(rk, icb: bytes, data: bytes) -> bytes:
    out = bytearray()
    cb = icb
    for i in range(0, len(data), 16):
        ks = _aes256_encrypt_block_rk(rk, cb)
        chunk = data[i:i + 16]
        out += bytes((a ^ b for a, b in zip(chunk, ks)))
        cb = _inc32(cb)
    return bytes(out)


def _gctr(key: bytes, icb: bytes, data: bytes) -> bytes:
    return _gctr_rk(_aes256_key_schedule(key), icb, data)


def aes_gcm_encrypt(key: bytes, nonce: bytes, plaintext: bytes, aad: bytes = b'') -> bytes:
    assert len(key) == 32 and len(nonce) == 12
    rk = _aes256_key_schedule(key)
    h = int.from_bytes(_aes256_encrypt_block_rk(rk, b'\x00' * 16), 'big')
    j0 = nonce + b'\x00\x00\x00\x01'
    ct = _gctr_rk(rk, _inc32(j0), plaintext)
    s = _ghash(h, aad, ct).to_bytes(16, 'big')
    tag = bytes((a ^ b for a, b in zip(_aes256_encrypt_block_rk(rk, j0), s)))
    return ct + tag


def aes_gcm_decrypt(key: bytes, nonce: bytes, ct_and_tag: bytes, aad: bytes = b'') -> bytes:
    if len(ct_and_tag) < 16:
        raise ValueError('AES-GCM payload too short')
    ct, tag = (ct_and_tag[:-16], ct_and_tag[-16:])
    rk = _aes256_key_schedule(key)
    h = int.from_bytes(_aes256_encrypt_block_rk(rk, b'\x00' * 16), 'big')
    j0 = nonce + b'\x00\x00\x00\x01'
    s = _ghash(h, aad, ct).to_bytes(16, 'big')
    expect = bytes((a ^ b for a, b in zip(_aes256_encrypt_block_rk(rk, j0), s)))
    if not _hmac.compare_digest(tag, expect):
        raise ValueError('AES-GCM decrypt failed')
    return _gctr_rk(rk, _inc32(j0), ct)


def _mgf1_sha256(seed: bytes, length: int) -> bytes:
    out = bytearray()
    counter = 0
    while len(out) < length:
        out += hashlib.sha256(seed + counter.to_bytes(4, 'big')).digest()
        counter += 1
    return bytes(out[:length])


def _oaep_encode_sha256(message: bytes, k: int, seed: bytes) -> bytes:
    hlen = 32
    if len(message) > k - 2 * hlen - 2:
        raise ValueError('OAEP message too long')
    lhash = hashlib.sha256(b'').digest()
    ps = b'\x00' * (k - len(message) - 2 * hlen - 2)
    db = lhash + ps + b'\x01' + message
    db_mask = _mgf1_sha256(seed, k - hlen - 1)
    masked_db = bytes((a ^ b for a, b in zip(db, db_mask)))
    seed_mask = _mgf1_sha256(masked_db, hlen)
    masked_seed = bytes((a ^ b for a, b in zip(seed, seed_mask)))
    return b'\x00' + masked_seed + masked_db


def _der_read_tlv(der: bytes, pos: int):
    assert der[pos] == 48, 'expected SEQUENCE'
    pos += 1
    ln, pos = _der_read_len(der, pos)
    end = pos + ln
    items = []
    while pos < end:
        tag = der[pos]
        pos += 1
        ln2, pos = _der_read_len(der, pos)
        items.append((tag, der[pos:pos + ln2]))
        pos += ln2
    return items


def _der_read_len(der: bytes, pos: int):
    first = der[pos]
    pos += 1
    if first & 128 == 0:
        return (first, pos)
    n = first & 127
    return (int.from_bytes(der[pos:pos + n], 'big'), pos + n)


def _der_read_int(raw: bytes) -> int:
    return int.from_bytes(raw, 'big')


@functools.lru_cache(maxsize=4)
def parse_spki_rsa_pubkey(der: bytes):
    outer = _der_read_tlv(der, 0)
    bitstring = outer[1][1]
    assert bitstring[0] == 0
    inner = _der_read_tlv(bitstring[1:], 0)
    n = _der_read_int(inner[0][1])
    e = _der_read_int(inner[1][1])
    return (n, e)


def rsa_oaep_sha256_encrypt(der: bytes, message: bytes, seed: bytes) -> bytes:
    n, e = parse_spki_rsa_pubkey(der)
    k = (n.bit_length() + 7) // 8
    em = _oaep_encode_sha256(message, k, seed)
    m = int.from_bytes(em, 'big')
    c = pow(m, e, n)
    return c.to_bytes(k, 'big')


class YsptpError(Exception):
    pass


def now_f64() -> float:
    return time.time()


def current_time_ms() -> int:
    return int(now_f64() * 1000.0)


def rust_round(x: float) -> float:
    return math.floor(x + 0.5)


def sha1_upper(value: str) -> str:
    return hashlib.sha1(value.encode('utf-8')).hexdigest().upper()


def sha256_hex(value: str) -> str:
    return hashlib.sha256(value.encode('utf-8')).hexdigest()


def md5_hex(value: str) -> str:
    return hashlib.md5(value.encode('utf-8')).hexdigest()


global_log_ring = collections.deque(maxlen=200)
_log_lock = threading.Lock()
_last_log_times = collections.OrderedDict()
QUIET = False


def log(msg, min_interval=0.0):
    if QUIET:
        return
    now = time.time()
    clean_msg = str(msg).strip()
    if not clean_msg:
        return
    with _log_lock:
        interval = min_interval if min_interval > 0.0 else 1.5
        last_t = _last_log_times.get(clean_msg, 0.0)
        if now - last_t < interval:
            return
        _last_log_times[clean_msg] = now
        _last_log_times.move_to_end(clean_msg)
        while len(_last_log_times) > 600:
            _last_log_times.popitem(last=False)
        line = '[%s] %s' % (time.strftime('%H:%M:%S'), clean_msg)
        global_log_ring.append(line)
    sys.stderr.write(line + '\n')


def java_string_hashcode(value: str) -> int:
    h = 0
    for ch in value:
        h = h * 31 + ord(ch) & 4294967295
    return h - 4294967296 if h & 2147483648 else h


def java_uuid_from_hashes(msb_hash: int, lsb_hash: int) -> str:
    msb = msb_hash & 18446744073709551615
    lsb = lsb_hash & 18446744073709551615
    return f'{msb << 64 | lsb:032x}'


def native_day0_ms(now_s: int) -> int:
    return 86400000 * ((now_s + 28800) // 86400) - 28800000


def compute_fingerprint(x_uid: str, now_ms: int):
    day0_ms = native_day0_ms(now_ms // 1000)
    first = sha256_hex(f'{AK}{x_uid}{now_ms}{day0_ms}')
    return (sha256_hex(first), now_ms, day0_ms)


def random_hex_string(length: int) -> str:
    return ''.join((secrets.choice('0123456789abcdef') for _ in range(length)))


def random_mac_address() -> str:
    raw = bytearray(secrets.token_bytes(6))
    raw[0] = (raw[0] | 2) & 254
    return ':'.join((f'{b:02x}' for b in raw))


def sanitize_profile_id(value: str) -> str:
    out = []
    last_underscore = False
    for ch in value:
        if ch.isascii() and ch.isalnum():
            out.append(ch.lower())
            last_underscore = False
        elif not last_underscore:
            out.append('_')
            last_underscore = True
    return ''.join(out).strip('_')


def resolution_from_screen_param(screen_param: str) -> str:
    parts = screen_param.split('-')
    if len(parts) >= 2 and parts[0] and parts[1]:
        return f'{parts[0]}*{parts[1]}'
    return '3840*2160'


# ================================================================ 真 Keep-Alive 连接池
class KeepAlivePool:
    """线程安全 Keep-Alive HTTP/HTTPS 连接池，支持 GET/POST、Cookie 与流式传输。"""

    def __init__(self, max_per_host=8, idle_ttl=30.0):
        self.max_per_host = max_per_host
        self.idle_ttl = idle_ttl
        self._lock = threading.Lock()
        self._pool = collections.defaultdict(collections.deque)
        self._insecure_hosts = set()
        self.reused = 0
        self.created = 0

    def _get_conn(self, scheme, host, port, timeout, force_insecure=False):
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
            insecure = force_insecure or _GLOBAL_INSECURE_TLS or (host in self._insecure_hosts)
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

    def request(self, method, url, headers=None, data=None, timeout=15.0,
                insecure_tls=False, max_redirects=5, stream=False, cookies=None):
        cur_url = url
        cur_method = method.upper()
        cur_data = data

        _p0 = urllib.parse.urlsplit(cur_url)
        if _proxy_for((_p0.scheme or 'http').lower(), _p0.hostname or '') is not None:
            _hdrs = {}
            for _k, _v in (headers or {}).items():
                if _v is not None:
                    _hdrs[_k] = str(_v)
            _st, _rsn, _rhdrs, _body, _final = _urllib_fetch(
                cur_method, cur_url, headers=_hdrs, data=cur_data,
                timeout=timeout, cookies=cookies
            )
            if stream and _st == 200:
                return _st, _rsn, _rhdrs, _BytesStreamAdapter(_body), _final, len(_body), (lambda ok=True: None)
            return _st, _rsn, _rhdrs, _body, _final, len(_body), None

        for _ in range(max_redirects + 1):
            p = urllib.parse.urlsplit(cur_url)
            scheme = (p.scheme or 'http').lower()
            host = p.hostname or ''
            port = p.port or (443 if scheme == 'https' else 80)
            path = (p.path or '/') + (('?' + p.query) if p.query else '')

            req_hdrs = {}
            for k, v in (headers or {}).items():
                if v is not None:
                    req_hdrs[k] = str(v)
            req_hdrs['Host'] = host if p.port is None else '%s:%d' % (host, port)
            req_hdrs.setdefault('Connection', 'Keep-Alive')
            req_hdrs.setdefault('Accept-Encoding', 'gzip')
            if cur_data is not None:
                req_hdrs['Content-Length'] = str(len(cur_data))
            if cookies:
                ck_str = '; '.join('%s=%s' % (k, v) for k, v in cookies.items())
                if ck_str:
                    req_hdrs['Cookie'] = ck_str

            last_exc = None
            for attempt in (0, 1):
                conn, from_pool = self._get_conn(scheme, host, port, timeout, force_insecure=insecure_tls)
                try:
                    conn.request(cur_method, path, body=cur_data, headers=req_hdrs)
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
                    last_exc = e
                    if 'CERTIFICATE_VERIFY_FAILED' in str(e) or isinstance(e, ssl.SSLError):
                        self.mark_insecure(host)
                        continue
                    if from_pool and attempt == 0:
                        continue
                    raise YsptpError(_normalize_network_error(e)) from e
            else:
                raise YsptpError(_normalize_network_error(last_exc or RuntimeError('request failed')))

            status = resp.status
            reason = resp.reason or ''
            resp_hdrs = {k.lower(): v for k, v in resp.getheaders()}
            if cookies is not None:
                for k, v in resp.getheaders():
                    if k.lower() == 'set-cookie':
                        m = re.match(r'\s*([^=;,\s]+)=([^;,\r\n]*)', v)
                        if m:
                            cookies[m.group(1)] = m.group(2)

            if status in (301, 302, 303, 307, 308):
                loc = resp.getheader('Location')
                _read_body_chunked(resp, max_bytes=1024 * 1024)
                if resp.will_close:
                    conn.close()
                else:
                    self._put_conn(scheme, host, port, conn)
                if not loc:
                    return status, reason, resp_hdrs, b'', cur_url, None, None
                cur_url = urllib.parse.urljoin(cur_url, loc)
                if status in (301, 302, 303) and cur_method == 'POST':
                    cur_method = 'GET'
                    cur_data = None
                continue

            ce = resp_hdrs.get('content-encoding', '').lower()
            cl_raw = resp_hdrs.get('content-length')
            cl = int(cl_raw) if cl_raw and cl_raw.isdigit() else None

            if stream and status == 200 and 'gzip' not in ce:
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
                return status, reason, resp_hdrs, resp, cur_url, cl, _release

            body = _read_body_chunked(resp)
            if resp.will_close:
                conn.close()
            else:
                self._put_conn(scheme, host, port, conn)

            if 'gzip' in ce or body[:2] == b'\x1f\x8b':
                try:
                    body = gzip.decompress(body)
                except (OSError, EOFError):
                    pass
            return status, reason, resp_hdrs, body, cur_url, len(body), None

        raise YsptpError('too many redirects')

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


_HTTP_POOL = KeepAlivePool()
_BG_POOL = _LazyBgPoolProxy(max_workers=2)


# ---- 设备身份 / 会话数据结构 / HTTP 客户端 ----
@dataclasses.dataclass
class DeviceProfile:
    android_id: str = ''
    mac: str = ''
    hardware: str = ''
    board: str = ''
    brand: str = ''
    device: str = ''
    manufacturer: str = ''
    model: str = ''
    product: str = ''
    tags: str = ''
    build_type: str = ''
    user: str = ''
    resolution: str = ''
    display: str = ''
    version_id: str = ''
    host: str = ''
    fingerprint: str = ''
    report_model: str = ''

    @classmethod
    def from_dict(cls, d: dict) -> 'DeviceProfile':
        return cls(**{f.name: str(d.get(f.name, '')) for f in dataclasses.fields(cls)})


@dataclasses.dataclass
class DeviceState:
    schema_version: int = 1
    profile_source: str = ''
    profile: DeviceProfile = dataclasses.field(default_factory=DeviceProfile)
    screen_param: str = ''
    cast_model: str = ''
    x_uid: str = ''
    cloud_guid: str = ''
    registered_at: float = 0.0
    updated_at: float = 0.0


@dataclasses.dataclass
class Identity:
    x_uid: str = ''
    x_fingerprint: str = ''
    fingerprint_timestamp_ms: int = 0
    headers: dict = dataclasses.field(default_factory=dict)


@dataclasses.dataclass
class ChannelEntry:
    channel: str = ''
    live_id: str = ''
    final_url: str = ''
    playback_headers: dict = dataclasses.field(default_factory=dict)
    android_id: str = ''
    x_uid: str = ''
    rate: str = ''
    rate_name: str = ''
    raw_live_host: str = ''
    final_host: str = ''
    refreshed_at: float = 0.0
    expires_at: float = 0.0
    generation: int = 0
    last_refresh_error: str = ''
    last_refresh_failed_at: float = 0.0
    session_generation: int = 0

    def fresh(self, now: float) -> bool:
        return bool(self.final_url) and now < self.expires_at

    def stale_usable(self, now: float, ttl: float) -> bool:
        return bool(self.final_url) and ttl > 0.0 and (now < self.expires_at + ttl)

    @classmethod
    def from_dict(cls, d: dict) -> 'ChannelEntry':
        kwargs = {}
        for f in dataclasses.fields(cls):
            v = d.get(f.name, f.default if f.default is not dataclasses.MISSING else None)
            if f.name == 'playback_headers':
                v = dict(v) if isinstance(v, dict) else {}
            kwargs[f.name] = v
        return cls(**kwargs)


@dataclasses.dataclass
class PlaylistCacheEntry:
    body: str = ''
    content_type: str = ''
    cached_at: float = 0.0
    expires_at: float = 0.0
    final_url: str = ''
    android_id: str = ''
    proxy_origin: str = ''
    proxy_prefix: str = ''


@dataclasses.dataclass
class PlaylistCacheProbe:
    state: str = ''
    age_ms: int | None = None


def inspect_playlist_cache(cached, entry: ChannelEntry, proxy_origin: str, proxy_prefix, now: float) -> PlaylistCacheProbe:
    if cached is None:
        return PlaylistCacheProbe(state='miss:not_found', age_ms=None)
    age_ms = int(rust_round(max(0.0, now - cached.cached_at) * 1000.0))
    fresh = now < cached.expires_at
    same_final_url = cached.final_url == entry.final_url
    same_android_id = cached.android_id == entry.android_id
    same_origin = cached.proxy_origin == proxy_origin
    same_prefix = cached.proxy_prefix == (proxy_prefix or '')
    if fresh and same_final_url and same_android_id and same_origin and same_prefix:
        return PlaylistCacheProbe(state='hit', age_ms=age_ms)
    reasons = []
    if not fresh:
        reasons.append('expired')
    if not same_final_url:
        reasons.append('final_url_changed')
    if not same_android_id:
        reasons.append('android_id_changed')
    if not same_origin:
        reasons.append('origin_changed')
    if not same_prefix:
        reasons.append('prefix_changed')
    if not reasons:
        reasons.append('unknown')
    return PlaylistCacheProbe(state='miss:' + '+'.join(reasons), age_ms=age_ms)


DEVICE_PROFILE_POOL = [
    {'source': 'sony_8k_pool.XR-85Z9K', 'brand': 'Sony', 'manufacturer': 'Sony', 'model': 'XR-85Z9K', 'report_model': 'XR85Z9K', 'hardware': 'mt5895', 'board': 'mt5895', 'version_id': 'SONYTV.2022.XR_85Z9K', 'screen_param': '7680-4320-280', 'cast_model': 'XR-85Z9K'},
    {'source': 'sony_8k_pool.XR-75Z9K', 'brand': 'Sony', 'manufacturer': 'Sony', 'model': 'XR-75Z9K', 'report_model': 'XR75Z9K', 'hardware': 'mt5895', 'board': 'mt5895', 'version_id': 'SONYTV.2022.XR_75Z9K', 'screen_param': '7680-4320-260', 'cast_model': 'XR-75Z9K'},
    {'source': 'sony_8k_pool.XR-85Z9J', 'brand': 'Sony', 'manufacturer': 'Sony', 'model': 'XR-85Z9J', 'report_model': 'XR85Z9J', 'hardware': 'mt5895', 'board': 'mt5895', 'version_id': 'SONYTV.2021.XR_85Z9J', 'screen_param': '7680-4320-280', 'cast_model': 'XR-85Z9J'},
    {'source': 'sony_8k_pool.XR-75Z9J', 'brand': 'Sony', 'manufacturer': 'Sony', 'model': 'XR-75Z9J', 'report_model': 'XR75Z9J', 'hardware': 'mt5895', 'board': 'mt5895', 'version_id': 'SONYTV.2021.XR_75Z9J', 'screen_param': '7680-4320-260', 'cast_model': 'XR-75Z9J'},
    {'source': 'samsung_8k_pool.QA85QN900C', 'brand': 'Samsung', 'manufacturer': 'Samsung', 'model': 'QA85QN900C', 'report_model': 'QA85QN900C', 'hardware': 's5e9935', 'board': 'neo8k', 'version_id': 'SAMSUNGTV.2023.QN900C', 'screen_param': '7680-4320-280', 'cast_model': 'QA85QN900C'},
    {'source': 'samsung_8k_pool.QA85QN900D', 'brand': 'Samsung', 'manufacturer': 'Samsung', 'model': 'QA85QN900D', 'report_model': 'QA85QN900D', 'hardware': 's5e9945', 'board': 'neo8k', 'version_id': 'SAMSUNGTV.2024.QN900D', 'screen_param': '7680-4320-280', 'cast_model': 'QA85QN900D'},
    {'source': 'lg_8k_pool.OLED88Z3PCA', 'brand': 'LG', 'manufacturer': 'LGE', 'model': 'OLED88Z3PCA', 'report_model': 'OLED88Z3PCA', 'hardware': 'alpha9gen6', 'board': 'lg8k', 'version_id': 'LGTV.2023.OLED88Z3', 'screen_param': '7680-4320-320', 'cast_model': 'OLED88Z3PCA'},
    {'source': 'lg_8k_pool.OLED88Z4PCA', 'brand': 'LG', 'manufacturer': 'LGE', 'model': 'OLED88Z4PCA', 'report_model': 'OLED88Z4PCA', 'hardware': 'alpha9gen7', 'board': 'lg8k', 'version_id': 'LGTV.2024.OLED88Z4', 'screen_param': '7680-4320-320', 'cast_model': 'OLED88Z4PCA'},
]


def random_device_template() -> dict:
    pool_8k = [t for t in DEVICE_PROFILE_POOL if '8k' in t.get('source', '')]
    return secrets.choice(pool_8k if pool_8k else DEVICE_PROFILE_POOL)


def device_profile_from_template(template: dict, android_id: str, mac: str) -> DeviceProfile:
    brand_id = sanitize_profile_id(template['brand'])
    model_id = sanitize_profile_id(template['model'])
    device = f'{brand_id}_{model_id}'
    product = f'{brand_id}_{model_id}'
    return DeviceProfile(
        android_id=android_id, mac=mac, hardware=template['hardware'], board=template['board'],
        brand=template['brand'], device=device, manufacturer=template['manufacturer'],
        model=template['model'], product=product, tags='release-keys', build_type='user',
        user='build', resolution=resolution_from_screen_param(template['screen_param']),
        display=f"{template['model']}-user 13 {template['version_id']} 2024 release-keys",
        version_id=template['version_id'], host=f'{brand_id}-tv-build',
        fingerprint=f"{template['manufacturer']}/{product}/{device}:13/{template['version_id']}/2024:user/release-keys",
        report_model=template['report_model']
    )


def default_device_state() -> DeviceState:
    template = random_device_template()
    profile = device_profile_from_template(template, random_hex_string(16), random_mac_address())
    return DeviceState(
        schema_version=1, profile_source=template['source'], profile=profile,
        screen_param=template['screen_param'], cast_model=template['cast_model'],
        x_uid=compute_x_uid(profile), cloud_guid='', registered_at=0.0, updated_at=now_f64()
    )


def load_device_state(path: str):
    try:
        with open(path, encoding='utf-8') as f:
            text = f.read()
    except OSError:
        return (default_device_state(), False)
    try:
        data = json.loads(text)
    except ValueError:
        return (default_device_state(), False)
    try:
        profile = DeviceProfile.from_dict(data.get('profile', {}))
        state = DeviceState(
            schema_version=int(data.get('schema_version', 1)),
            profile_source=str(data.get('profile_source', '')),
            profile=profile,
            screen_param=str(data.get('screen_param', '')),
            cast_model=str(data.get('cast_model', '')),
            x_uid=str(data.get('x_uid', '')),
            cloud_guid=str(data.get('cloud_guid', '')),
            registered_at=float(data.get('registered_at', 0.0)),
            updated_at=float(data.get('updated_at', 0.0)),
        )
    except (ValueError, TypeError, AttributeError):
        return (default_device_state(), False)
    if len(state.profile.android_id) != 16 or not state.profile.mac:
        return (default_device_state(), False)
    state.x_uid = compute_x_uid(state.profile)
    if not state.screen_param:
        state.screen_param = '7680-4320-280'
    if not state.cast_model:
        state.cast_model = state.profile.model
    return (state, True)


def save_device_state(path: str, state: DeviceState) -> None:
    tmp_path = path + f'.tmp.{os.getpid()}'
    try:
        parent = os.path.dirname(os.path.abspath(path))
        if parent:
            os.makedirs(parent, exist_ok=True)
        with open(tmp_path, 'w', encoding='utf-8') as f:
            f.write(json.dumps(dataclasses.asdict(state), indent=2, ensure_ascii=False, sort_keys=True) + '\n')
            f.flush()
            os.fsync(f.fileno())
        os.replace(tmp_path, path)
    except OSError:
        try:
            if os.path.exists(tmp_path):
                os.remove(tmp_path)
        except OSError:
            pass


def infer_os_version(profile: DeviceProfile) -> str:
    if ':' in profile.fingerprint:
        tail = profile.fingerprint.split(':', 1)[1]
        if '/' in tail:
            return tail.split('/', 1)[0]
    return ''


def compute_x_uid(profile: DeviceProfile) -> str:
    build_identity_str = (
        '1698' + profile.hardware + profile.board + profile.brand + profile.device +
        profile.manufacturer + profile.model + profile.product + profile.tags +
        profile.build_type + profile.user + profile.resolution + profile.mac
    )
    uuid_part = java_uuid_from_hashes(java_string_hashcode(build_identity_str), java_string_hashcode(profile.model))
    return sha1_upper(f'{profile.android_id}|{uuid_part}')


def build_identity(profile: DeviceProfile, app_channel: str, version: str) -> Identity:
    x_uid = compute_x_uid(profile)
    x_fingerprint, ts, _day0 = compute_fingerprint(x_uid, current_time_ms())
    headers = {
        'Accept': 'application/json',
        'Accept-Language': DEFAULT_ACCEPT_LANGUAGE,
        'Referer': 'api.cctv.cn',
        'User-Agent': 'cctv_app_tv',
        'UID': profile.android_id,
        'appChannel': app_channel,
        'X-Uid': x_uid,
        'X-Fingerprint': x_fingerprint,
        'X-Version': version,
        'Content-Type': 'application/json; charset=utf-8',
        'Connection': 'Keep-Alive',
        'Accept-Encoding': 'gzip',
        'Cache-Control': 'no-cache',
    }
    return Identity(x_uid=x_uid, x_fingerprint=x_fingerprint, fingerprint_timestamp_ms=ts, headers=headers)


def next_request_timestamp_ms() -> int:
    return current_time_ms()


def fresh_headers(template: dict, content_type: str, accept=None, force_ts=None) -> dict:
    headers = {}
    if accept is not None:
        headers['Accept'] = accept
    req_ts = force_ts if force_ts is not None else next_request_timestamp_ms()
    headers['X-Timestamp'] = str(req_ts)
    headers['X-Nonce'] = str(uuid.uuid4())
    for key in ('Accept-Language', 'Referer', 'User-Agent', 'UID', 'appChannel', 'X-Uid', 'X-Fingerprint', 'X-Version'):
        if key in template:
            headers[key] = template[key]
    if content_type:
        headers['Content-Type'] = content_type
    for key in ('Connection', 'Accept-Encoding', 'Cache-Control'):
        if key in template:
            headers[key] = template[key]
    return headers


def compact_json_bytes(value, escape_forward_slashes: bool) -> bytes:
    text = json.dumps(value, separators=(',', ':'), ensure_ascii=False, sort_keys=True)
    if escape_forward_slashes:
        text = text.replace('/', '\\/')
    return text.encode('utf-8')


def normalize_aes_key(value: str) -> bytes:
    raw = value.encode('utf-8')
    return (raw + b'\x00' * 32)[:32]


def aes_gcm_decrypt_b64(value: str, key: str) -> str:
    try:
        raw = base64.b64decode(value, validate=True)
    except (binascii.Error, ValueError) as e:
        raise YsptpError(f'base64 decode failed: {e}')
    if len(raw) <= 12:
        raise YsptpError('AES-GCM payload too short')
    try:
        plain = aes_gcm_decrypt(normalize_aes_key(key), raw[:12], raw[12:])
    except ValueError:
        raise YsptpError('AES-GCM decrypt failed')
    try:
        return plain.decode('utf-8')
    except UnicodeDecodeError as e:
        raise YsptpError(f'AES-GCM plaintext is not UTF-8: {e}')


def aes_gcm_encrypt_b64(value: str, key: str) -> str:
    nonce = secrets.token_bytes(12)
    try:
        encrypted = aes_gcm_encrypt(normalize_aes_key(key), nonce, value.encode('utf-8'))
    except ValueError:
        raise YsptpError('AES-GCM encrypt failed')
    return base64.b64encode(nonce + encrypted).decode('ascii')


def rsa_encrypt_device_id(device_id: str) -> str:
    try:
        der = base64.b64decode(RSA_PUBLIC_KEY_B64, validate=True)
    except (binascii.Error, ValueError) as e:
        raise YsptpError(f'RSA public key base64 decode failed: {e}')
    n, e = parse_spki_rsa_pubkey(der)
    k = (n.bit_length() + 7) // 8
    hlen = 32
    chunk_size = k - 2 * hlen - 2
    out = bytearray()
    data = device_id.encode('utf-8')
    for i in range(0, len(data), chunk_size):
        chunk = data[i:i + chunk_size]
        out += rsa_oaep_sha256_encrypt(der, chunk, secrets.token_bytes(hlen))
    return base64.b64encode(bytes(out)).decode('ascii')


def report_model_from_build(profile: DeviceProfile) -> str:
    return profile.model.replace(profile.manufacturer, '').replace(' ', '')


def app_start_field(value, limit: int) -> str:
    return str(value)[:limit] if limit >= 0 else str(value)


def build_report_common_value(profile: DeviceProfile, x_uid: str, app_channel: str, version: str, sdk_version: str, data_time_ms: int) -> dict:
    model = profile.report_model or report_model_from_build(profile)
    return {
        'cctv_id': app_start_field(x_uid, 64),
        'device_id': app_start_field(profile.android_id, 64),
        'idfa': '', 'idfv': '', 'user_id': '',
        'app_key': app_start_field(REPORT_APP_KEY, 64),
        'imei': '',
        'android_id': app_start_field(profile.android_id, 64),
        'mac': app_start_field(profile.mac, 64),
        'device_builder_type': app_start_field(profile.build_type, 64),
        'device_hardware': app_start_field(profile.hardware, 64),
        'device_board': app_start_field(profile.board, 64),
        'device_brand': app_start_field(profile.brand, 64),
        'device_params': app_start_field(profile.device, 64),
        'device_display': app_start_field(profile.display, 64),
        'device_version_id': app_start_field(profile.version_id, 64),
        'device_host': app_start_field(profile.host, 128),
        'device_product': app_start_field(profile.product, 64),
        'device_tags': app_start_field(profile.tags, 64),
        'device_user': app_start_field(profile.user, 30),
        'device_fingerprint': app_start_field(profile.fingerprint, 128),
        'device_manufacturer': app_start_field(profile.manufacturer, 64),
        'device_model': app_start_field(model, 50),
        'device_resolution': app_start_field(profile.resolution, 20),
        'system_type': 'Android', 'device_type': 'TV', 'app_language': 'CHINESE',
        'app_version': app_start_field(version, 30),
        'sdk_version': app_start_field(sdk_version, 30),
        'os_version': app_start_field(infer_os_version(profile), 20),
        'app_channel': app_start_field(app_channel, 50),
        'data_time': app_start_field(data_time_ms, 13)
    }


def build_app_start_body(profile: DeviceProfile, x_uid: str, app_channel: str, version: str, data_time_ms: int) -> dict:
    return {'key': 'app_start_d1', 'value': build_report_common_value(profile, x_uid, app_channel, version, '', data_time_ms)}


def parse_result_code(value) -> int | None:
    if isinstance(value, dict):
        for key in ('result', 'code', 'errCode', 'errcode', 'ret'):
            if key in value:
                raw = value[key]
                if isinstance(raw, bool):
                    continue
                if isinstance(raw, int):
                    return raw
                if isinstance(raw, str):
                    try:
                        return int(raw)
                    except ValueError:
                        pass
        for key in ('data', 'error', 'response'):
            if key in value:
                found = parse_result_code(value[key])
                if found is not None:
                    return found
    return None


def extract_guid(value) -> str:
    if isinstance(value, dict):
        data = value.get('data')
        if isinstance(data, dict):
            guid = data.get('guid')
            if isinstance(guid, str):
                return guid
    return ''


def build_vdn_appcommon(version: str) -> str:
    return json.dumps({'adid': '', 'av': version, 'an': VDN_APP_NAME, 'ap': 'cctv_app_tv'}, separators=(',', ':'), ensure_ascii=False, sort_keys=True)


def url_host(url: str) -> str:
    try:
        return urllib.parse.urlsplit(url).hostname or ''
    except ValueError:
        return ''


def live_playback_host_needs_signed_headers(host: str) -> bool:
    lower = host.lower()
    return 'liveali' in lower or 'liveten' in lower


def default_cctv_playback_headers(uid: str) -> dict:
    return {'UID': uid, 'APPID': AK, 'Referer': 'api.cctv.cn', 'User-Agent': 'cctv_app_tv'}


def generate_app_random_str() -> str:
    return f'{secrets.randbits(32):08x}-0000-{secrets.randbits(32) & 65535:04x}-0000-00000000{secrets.randbits(32) & 65535:04x}'


def compute_vdn_code(app_secret: str, random_str=None):
    r = random_str if random_str is not None else generate_app_random_str()
    return (md5_hex(f'{AK}{app_secret}{r}'), r)


def form_urlencode_value(s: str) -> str:
    out = []
    for byte in s.encode('utf-8'):
        ch = chr(byte)
        if ch.isascii() and (ch.isalnum() or ch in '*-._'):
            out.append(ch)
        elif byte == 32:
            out.append('+')
        else:
            out.append(f'%{byte:02X}')
    return ''.join(out)


def form_encode(pairs) -> bytes:
    return '&'.join((f'{form_urlencode_value(k)}={form_urlencode_value(v)}' for k, v in pairs)).encode('utf-8')


def _normalize_network_error(e: Exception) -> str:
    if isinstance(e, ConnectionRefusedError):
        return f'connection refused: {e}'
    if isinstance(e, ConnectionResetError):
        return f'connection reset by peer: {e}'
    if isinstance(e, (socket.timeout, TimeoutError)):
        return f'operation timed out: {e}'
    if isinstance(e, socket.gaierror):
        return f'failed to lookup address: {e}'
    if isinstance(e, urllib.error.URLError):
        reason = e.reason
        if isinstance(reason, Exception):
            return _normalize_network_error(reason)
        return f'network error: {e}'
    return f'network error: {e}'


class HttpResponse:
    def __init__(self, status: int, reason: str, headers: dict, body: bytes):
        self.status = status
        self.reason = reason
        self.headers = headers
        self.body = body

    def text(self) -> str:
        return self.body.decode('utf-8', errors='replace')


class HttpClient:
    """基于全局 KeepAlivePool 的高性能 HTTP 客户端（自动维护会话 Cookie）。"""

    def __init__(self, timeout: float, insecure_tls: bool):
        self._timeout = max(timeout, 0.1)
        self._insecure = insecure_tls
        self._cookies = {}

    def _send(self, method: str, url: str, headers: dict, data: bytes | None) -> HttpResponse:
        status, reason, hdrs, body, _, _, _ = _HTTP_POOL.request(
            method, url, headers=headers, data=data,
            timeout=self._timeout, insecure_tls=self._insecure, cookies=self._cookies
        )
        return HttpResponse(status, reason, hdrs, body)

    def get(self, url: str, headers: dict) -> HttpResponse:
        return self._send('GET', url, headers, None)

    def post_bytes(self, url: str, headers: dict, data: bytes) -> HttpResponse:
        return self._send('POST', url, headers, data)

    def post_json(self, url: str, headers: dict, body) -> HttpResponse:
        data = json.dumps(body, separators=(',', ':'), ensure_ascii=False, sort_keys=True).encode('utf-8')
        return self._send('POST', url, headers, data)

    def post_form(self, url: str, headers: dict, pairs) -> HttpResponse:
        return self._send('POST', url, headers, form_encode(pairs))


def response_json(resp: HttpResponse):
    status = resp.status
    text = resp.text()
    try:
        value = json.loads(text)
    except ValueError:
        value = None
    return (status, text, value)


# ---- JCE 序列化（时移请求）----
class W:
    def __init__(self):
        self.b = bytearray()

    def head(self, typ, tag):
        if tag < 15:
            self.b.append((tag & 15) << 4 | typ & 15)
        else:
            self.b.append(240 | typ & 15)
            self.b.append(tag)

    def byte(self, v, tag):
        v = int(v)
        if v == 0:
            self.head(12, tag)
        else:
            self.head(0, tag)
            self.b += struct.pack('>b', v)

    def short(self, v, tag):
        v = int(v)
        if -128 <= v <= 127:
            self.byte(v, tag)
        else:
            self.head(1, tag)
            self.b += struct.pack('>h', v)

    def int(self, v, tag):
        v = int(v)
        if -32768 <= v <= 32767:
            self.short(v, tag)
        else:
            self.head(2, tag)
            self.b += struct.pack('>i', v)

    def long(self, v, tag):
        v = int(v)
        if -2147483648 <= v <= 2147483647:
            self.int(v, tag)
        else:
            self.head(3, tag)
            self.b += struct.pack('>q', v)

    def float(self, v, tag):
        self.head(4, tag)
        self.b += struct.pack('>f', float(v))

    def double(self, v, tag):
        self.head(5, tag)
        self.b += struct.pack('>d', float(v))

    def string(self, s, tag):
        if s is None:
            return
        data = str(s).encode('utf-8')
        if len(data) > 255:
            self.head(7, tag)
            self.b += struct.pack('>i', len(data))
            self.b += data
        else:
            self.head(6, tag)
            self.b.append(len(data))
            self.b += data

    def bytes(self, data, tag):
        data = bytes(data)
        self.head(13, tag)
        self.head(0, 0)
        self.int(len(data), 0)
        self.b += data

    def struct(self, fn, tag):
        self.head(10, tag)
        fn(self)
        self.head(11, 0)

    def list(self, items, tag, wf):
        self.head(9, tag)
        self.int(len(items), 0)
        if wf is not None:
            for item in items:
                wf(self, item)

    def out(self):
        return bytes(self.b)


class R:
    def __init__(self, data):
        self.d = memoryview(data)
        self.p = 0

    def rem(self):
        return len(self.d) - self.p

    def get(self, n):
        if self.p + n > len(self.d):
            raise EOFError
        b = self.d[self.p:self.p + n].tobytes()
        self.p += n
        return b

    def u8(self):
        return self.get(1)[0]

    def head(self):
        b = self.u8()
        typ = b & 15
        tag = (b & 240) >> 4
        if tag == 15:
            tag = self.u8()
        return (typ, tag)

    def value(self, typ):
        if typ == 0:
            return struct.unpack('>b', self.get(1))[0]
        if typ == 1:
            return struct.unpack('>h', self.get(2))[0]
        if typ == 2:
            return struct.unpack('>i', self.get(4))[0]
        if typ == 3:
            return struct.unpack('>q', self.get(8))[0]
        if typ == 4:
            return struct.unpack('>f', self.get(4))[0]
        if typ == 5:
            return struct.unpack('>d', self.get(8))[0]
        if typ == 6:
            n = self.u8()
            return self.get(n).decode('utf-8', 'replace')
        if typ == 7:
            n = struct.unpack('>i', self.get(4))[0]
            return self.get(n).decode('utf-8', 'replace')
        if typ == 8:
            n = self._int()
            return {self._fv(): self._fv() for _ in range(n)}
        if typ == 9:
            n = self._int()
            return [self._fv() for _ in range(n)]
        if typ == 10:
            return self.struct()
        if typ == 11:
            return None
        if typ == 12:
            return 0
        if typ == 13:
            t, _ = self.head()
            n = self._int()
            return self.get(n)
        raise ValueError('type %d' % typ)

    def _fv(self):
        t, _ = self.head()
        return self.value(t)

    def _int(self):
        t, _ = self.head()
        return int(self.value(t))

    def struct(self):
        m = {}
        while self.rem() > 0:
            t, tag = self.head()
            if t == 11:
                break
            m[tag] = self.value(t)
        return m


VER_NAME, VER_CODE = ('3.2.7.26212', '302070')
APP_ID, QMF_APP_ID, QMF_PLATFORM, BIZ_ID = ('1200013', 10012, 1, 0)
CHAN_ID = '10070'
GUID = ''.join((random.choice('0123456789abcdef') for _ in range(32)))


def _qua(w):
    w.string(VER_NAME, 0)
    w.string(VER_CODE, 1)
    w.int(1080, 2)
    w.int(2400, 3)
    w.int(3, 4)
    w.string('12', 5)
    w.int(1, 6)
    w.int(1, 7)
    w.int(420, 8)
    w.string(CHAN_ID, 9)
    for i in range(10, 15):
        w.string('', i)
    w.struct(lambda ww: (ww.int(0, 0), ww.byte(0, 1), ww.string('', 2)), 15)
    w.string('', 16)
    w.string('', 17)
    w.string('', 18)
    w.struct(lambda ww: (ww.int(0, 0), ww.float(0, 1), ww.float(0, 2), ww.double(0, 3)), 19)
    w.string(GUID[:16], 20)
    w.string('Pixel 6', 21)
    w.int(1, 22)
    for i in range(23, 27):
        w.int(0, i)
    w.string('', 27)
    w.string('', 28)
    w.string(GUID, 29)


def _head(w, cmd, reqid):
    w.int(reqid, 0)
    w.int(cmd, 1)
    w.struct(lambda ww: _qua(ww), 2)
    w.string(APP_ID, 3)
    w.string(GUID, 4)
    w.list([], 5, None)
    w.struct(lambda ww: None, 6)
    w.list([], 7, None)
    w.int(0, 8)
    w.int(0, 9)
    w.int(0, 10)


def _wrap(cmd, body, reqid):
    w = W()
    w.struct(lambda ww: _head(ww, cmd, reqid), 0)
    w.bytes(body, 1)
    reqcmd = w.out()
    inner = bytearray([38]) + struct.pack('>i', len(reqcmd) + 17) + bytes([1]) + b'\x00' * 10 + reqcmd + bytes([40])
    comp = gzip.compress(bytes(inner))
    out = bytearray([19]) + struct.pack('>i', 0) + struct.pack('>H', 2) + struct.pack('>H', 65281)
    out += struct.pack('>H', cmd) + struct.pack('>H', 0) + struct.pack('>q', reqid)
    out += struct.pack('>i', 531) + struct.pack('>i', QMF_APP_ID) + struct.pack('>q', BIZ_ID)
    g = GUID.encode()[:32]
    out += g + b'\x00' * (32 - len(g))
    out += struct.pack('>b', QMF_PLATFORM) + struct.pack('>i', int(VER_CODE)) + b'\x00' * 6
    out += bytes([0]) + struct.pack('>H', 0) + struct.pack('>H', 0)
    out += struct.pack('>i', len(inner)) + comp + bytes([3])
    struct.pack_into('>i', out, 1, len(out))
    return bytes(out)


def _unwrap(data):
    if data[:1] != b'\x13' or len(data) < 90:
        return None
    flags = struct.unpack('>i', data[21:25])[0]
    payload = data[89:-1]
    if flags & 2:
        payload = gzip.decompress(payload)
    if payload[:1] != b'&' or payload[-1:] != b'(':
        return None
    rc = R(payload[16:-1]).struct()
    return rc.get(1) or b''


class DeadHostError(RuntimeError):
    pass


def jce_timeshift_url(pid, sid, start, end, stream='fhd'):
    w = W()
    w.string(pid, 0)
    w.string(sid, 1)
    w.long(start, 2)
    w.long(end, 3)
    w.string(stream, 4)
    body = w.out()
    CMD = 25312
    reqid = int(time.time() * 1000) & 2147483647
    packet = _wrap(CMD, body, reqid)
    status, _, _, raw, _, _, _ = _HTTP_POOL.request(
        'POST', 'https://jacc.ysp.cctv.cn',
        headers={'Content-Type': 'application/octet-stream', 'User-Agent': UA},
        data=packet, timeout=15.0
    )
    if status != 200:
        raise RuntimeError('jacc HTTP %s' % status)
    resp_body = _unwrap(raw)
    if not resp_body:
        raise RuntimeError('bad response')
    m = R(resp_body).struct()
    err = m.get(0, 0)
    if err != 0:
        raise RuntimeError(m.get(1, 'errCode=%s' % err))
    url = m.get(2, '')
    if not url:
        raise RuntimeError('empty m3u8')
    if 'liverecord.video.cloud.cctv.com' in url:
        raise DeadHostError('dead cdn host')
    return url


# ---- cKey 签名 ----
_CK_PLATFORM = 4330403
_CK_APPVER = 'V8.22.1035.3031'
_CK_TEA = bytes.fromhex('59b2f7cf725ef43c34fdd7c123411ed3')
_CK_GTEA = bytes.fromhex('110DBEC10C23E7D2E56A1CAD6914EF1B')
_CK_XOR = bytes([132, 46, 237, 8, 240, 102, 230, 234, 72, 180, 202, 169, 145, 237, 111, 243])
_CK_GXOR = bytes([179, 201, 83, 160, 105, 19, 173, 77])


def _u32(v):
    return v & 4294967295


def _tea_blk(blk, key):
    y, z = struct.unpack('>2I', blk)
    k = struct.unpack('>4I', key)
    s = 0
    for _ in range(16):
        s = _u32(s + 2654435769)
        y = _u32(y + _u32(_u32(_u32(z << 4) + k[0]) ^ _u32(z + s) ^ _u32((z >> 5) + k[1])))
        z = _u32(z + _u32(_u32(_u32(y << 4) + k[2]) ^ _u32(y + s) ^ _u32((y >> 5) + k[3])))
    return struct.pack('>2I', y, z)


def _cksum(buf):
    v = 0
    for b in buf:
        v = 131 * v + b & 2147483647
    return v


def _tea_pkt(data, key):
    pad = (8 - (len(data) + 10) % 8) % 8
    plain = bytes([os.urandom(1)[0] & 248 | pad]) + os.urandom(pad) + os.urandom(2) + data + bytes(7)
    out, pp, pc = (b'', bytes(8), bytes(8))
    for off in range(0, len(plain), 8):
        mixed = bytes((a ^ b for a, b in zip(plain[off:off + 8], pc)))
        enc = _tea_blk(mixed, key)
        cipher = bytes((a ^ b for a, b in zip(enc, pp)))
        out += cipher
        pp, pc = (mixed, cipher)
    return out


def _lp(s):
    d = s.encode() if isinstance(s, str) else s
    return struct.pack('>H', len(d)) + d


def _ck_guard(ts, guid):
    def tail(v):
        t = str(v)
        return t[-5:] if len(t) >= 5 else ''

    body = struct.pack('>I', ts) + _lp(tail(guid)) + _lp(tail('null')) + _lp(tail('null')) + _lp('-1')
    plain = _lp(body)
    enc = _tea_pkt(plain, _CK_GTEA) + struct.pack('>I', _cksum(plain))
    enc = bytes((a ^ _CK_GXOR[i & 7] for i, a in enumerate(enc)))
    return enc.hex().upper()


def _ckey(channel_id):
    ts = int(time.time())
    guid = os.urandom(16).hex()
    guard = _ck_guard(ts, guid)
    uid = os.urandom(4).hex().upper()
    body = (
        bytes.fromhex('0000004200000004000004d2') +
        struct.pack('>I', _CK_PLATFORM) + struct.pack('>I', 0) + struct.pack('>I', ts) +
        _lp('dcgh') + _lp('_zj1A5Gh6QYcxWjIUGos2w==') + _lp(_CK_APPVER) +
        _lp(str(channel_id)) + _lp(guid) + struct.pack('>I', 1) + struct.pack('>I', 1) +
        _lp(uid) + _lp('nil') + _lp('57eab0c4-2c58-44c6-8ae9-dd2757525dc5') +
        _lp('nil') + _lp('v0.1.000') + _lp('com.cctv.yangshipin.app.iphone') +
        _lp(str(_CK_PLATFORM)) + _lp('ex_json_bus') + _lp('ex_json_vs') + _lp(guard)
    )
    pkt = bytearray(struct.pack('>H', len(body)) + body)
    pkt[18:22] = struct.pack('>I', _cksum(bytes(pkt)))
    pkt = bytes(pkt)
    enc = _tea_pkt(pkt, _CK_TEA) + struct.pack('>I', _cksum(pkt))
    enc = bytes((a ^ _CK_XOR[i & 15] for i, a in enumerate(enc)))
    b64 = base64.b64encode(enc).decode().replace('+', '_').replace('/', '-').rstrip('=')
    return {'cKey': '--01' + b64, 'guid': guid, 'ts': ts, 'flowId': '%s_%d' % (uuid.uuid4().hex.upper(), _CK_PLATFORM)}


_BK_H264 = base64.b64encode(b'H(30:1080,60:1080|30:1080,60:1080)').decode()


# ===========================================================================
# v2.1.3 运行时：高码率设备协议 / JCE 时移 / TS 单飞流式缓存 / EPG / M3U 服务
# ===========================================================================
APP_VERSION_CODE = '300090'
APP_CHANNEL = 'dangbei'
TV_VERSION = '1.4.1'
VA = 'application/json'
HIGH_RATE = {'cctv4k', 'cctv8k', 'cctv164k'}
EPG_SOURCES = [
    'https://epg.zsdc.eu.org/t.xml.gz',
    'https://epg.pw/xmltv/epg_CN.xml.gz',
]


class PluginError(RuntimeError):
    pass


# ---------------------------------------------------------------------------
# 1080p：cKey + bkliveinfo（复用连接池）
# ---------------------------------------------------------------------------
def bk_resolve(slug, defn=None, timeout=10.0):
    meta = CHANNELS[slug]
    t = _ckey(meta['sid'])
    q = {
        'atime': '120', 'livepid': meta['pid'], 'cnlid': meta['sid'],
        'appVer': _CK_APPVER, 'app_version': APP_VERSION_CODE, 'caplv': '1',
        'cmd': '2', 'defn': defn or meta['defn'], 'device': 'iPhone',
        'encryptVer': '4.2', 'getpreviewinfo': '0', 'hevclv': '0',
        'lang': 'zh-Hans_CN', 'livequeue': '0', 'logintype': '1', 'nettype': '1',
        'newnettype': '1', 'newplatform': str(_CK_PLATFORM), 'platform': str(_CK_PLATFORM),
        'sdtfrom': 'v3021', 'spacode': '23', 'spaudio': '1', 'spdemuxer': '6',
        'spdrm': '2', 'spdynamicrange': '1', 'spflv': '1', 'spflvaudio': '1',
        'sphdrfps': '60', 'sphttps': '1', 'spvcode': _BK_H264, 'spvideo': '4',
        'stream': '1', 'system': '1', 'sysver': 'ios18.2.1', 'uhd_flag': '0',
        'cKey': t['cKey'], 'guid': t['guid'], 'fntick': str(t['ts']),
        'flowid': t['flowId'], 'playbacktime': '0',
    }
    url = 'https://bkliveinfo.ysp.cctv.cn/?' + urllib.parse.urlencode(q)
    try:
        status, _, _, raw, _, _, _ = _HTTP_POOL.request(
            'GET', url, headers={'User-Agent': 'qqlive', 'Accept': 'application/json'}, timeout=timeout
        )
        if status != 200:
            raise PluginError('bkliveinfo HTTP %s' % status)
    except Exception as e:  # noqa: BLE001
        raise PluginError('bkliveinfo 请求失败: %s' % e)
    p = json.loads(raw.decode('utf-8', 'replace'))
    if int(p.get('iretcode', -1)) != 0:
        raise PluginError('bkliveinfo iretcode=%s %s' % (p.get('iretcode'), p.get('errinfo', '')))
    urls = []
    for u in [p.get('playurl')] + (p.get('backurl_list') or []):
        if isinstance(u, dict):
            u = u.get('url') or u.get('playurl')
        if isinstance(u, str) and u and u not in urls:
            urls.append(u)
    hs = p.get('http_header') or {}
    if not urls:
        raise PluginError('bkliveinfo 无播放地址')
    return {'urls': urls, 'headers': hs, 'mode': 'liveinfo', 'defn': p.get('defn', '')}


# ---------------------------------------------------------------------------
# 高码率：设备注册（ytpcloudws）+ live/v1/01 + VDN
# ---------------------------------------------------------------------------
class DeviceSession(object):
    def __init__(self, state_path, timeout=10.0):
        self.state_path = state_path
        self.timeout = timeout
        self.client = HttpClient(timeout, False)
        self.profile = None
        self.identity = None
        self.session_key = ''
        self.cloud_guid = ''
        self.screen_param = ''
        self.cast_model = ''
        self.created_at = 0.0
        self.last_heartbeat_at = 0.0
        self.last_error = ''

    def bootstrap(self):
        """建立设备会话；注册失败（empty guid）时换一套设备身份重试一次。"""
        last = ''
        for attempt in range(2):
            st, existed = load_device_state(self.state_path)
            if attempt > 0 or not existed or st.registered_at <= 0.0:
                st = default_device_state()
            self.profile = st.profile
            self.identity = build_identity(st.profile, APP_CHANNEL, TV_VERSION)
            st.x_uid = self.identity.x_uid
            self.screen_param = st.screen_param
            self.cast_model = st.cast_model
            try:
                self.session_key = self.app_start()
                guid = self.cloud_register()
            except (PluginError, YsptpError) as e:
                last = str(e)
                log('设备注册第 %d 次失败: %s' % (attempt + 1, e))
                continue
            if not guid:
                guid = st.cloud_guid
            if not guid:
                last = 'cloud device registration failed: empty guid'
                log('设备注册第 %d 次返回空 guid，换设备身份重试' % (attempt + 1))
                time.sleep(0.8)
                continue
            self.cloud_guid = guid
            st.cloud_guid = guid
            st.updated_at = now_f64()
            if st.registered_at <= 0.0:
                st.registered_at = now_f64()
            try:
                save_device_state(self.state_path, st)
            except OSError:
                pass
            self.created_at = now_f64()
            try:
                self.heartbeat()
            except Exception:  # noqa: BLE001
                pass
            return self
        raise PluginError(last or '设备注册失败')

    def app_start(self):
        last = ''
        for attempt in range(2):
            if attempt:
                time.sleep(attempt * 0.5)
            ts = current_time_ms()
            xfp, fp_ts, _ = compute_fingerprint(self.identity.x_uid, ts)
            self.identity.x_fingerprint = xfp
            self.identity.headers['X-Fingerprint'] = xfp
            body = build_app_start_body(self.profile, self.identity.x_uid, APP_CHANNEL,
                                        TV_VERSION, current_time_ms())
            headers = fresh_headers(self.identity.headers, VA, VA, fp_ts)
            headers['UID'] = ''
            resp = self.client.post_bytes(APP_START_URL, headers, compact_json_bytes(body, True))
            status, _, value = response_json(resp)
            if 200 <= status < 300:
                data = value.get('data') if isinstance(value, dict) else None
                enc = ''
                if isinstance(data, dict):
                    kv = data.get('key', data)
                    enc = kv if isinstance(kv, str) else ''
                elif isinstance(data, str):
                    enc = data
                if enc:
                    return aes_gcm_decrypt_b64(enc, xfp[:32])
            last = 'app/start HTTP %s' % status
        raise PluginError(last)

    def cloud_register(self):
        body = {'device_name': DEFAULT_DEVICE_NAME,
                'device_id': rsa_encrypt_device_id(self.identity.x_uid)}
        resp = self.client.post_json(CLOUD_GET_URL,
                                     fresh_headers(self.identity.headers, VA, VA, None), body)
        _, _, value = response_json(resp)
        code = parse_result_code(value)
        if code == RESULT_OK:
            return extract_guid(value)
        if code not in (RESULT_NEEDS_REGISTER, RESULT_GET_MISSING_OR_INVALID):
            return ''
        guid = ''
        for _ in range(2):
            resp = self.client.post_json(CLOUD_REGISTER_URL,
                                         fresh_headers(self.identity.headers, VA, VA, None), body)
            _, _, value = response_json(resp)
            code = parse_result_code(value)
            guid = extract_guid(value)
            if guid or code != RESULT_REGISTER_RETRY_LATER:
                break
        return guid

    def heartbeat(self):
        body = {'key': 'app_heartbeat', 'value': build_report_common_value(
            self.profile, self.identity.x_uid, APP_CHANNEL, TV_VERSION, '', current_time_ms())}
        body['value']['guid'] = self.cloud_guid
        resp = self.client.post_json(REPORT_SINGLE_URL,
                                     fresh_headers(self.identity.headers, VA, VA, None), body)
        self.last_heartbeat_at = now_f64()
        return resp.status

    def live_url(self, live_id):
        body = {'screenParam': self.screen_param, 'rate': '', 'systemType': 'ios',
                'model': self.cast_model, 'id': live_id, 'userId': DEFAULT_LIVE_USER_ID,
                'clientSign': 'cctvVideo',
                'deviceId': {'serial': '', 'imei': '', 'android_id': ''}}
        resp = self.client.post_json(LIVE_V1_01_URL,
                                     fresh_headers(self.identity.headers, VA, VA, None), body)
        status, _, value = response_json(resp)
        if not 200 <= status < 300:
            raise PluginError('live/v1/01 HTTP %s' % status)
        videos = (value.get('data') or {}).get('videoList') if isinstance(value, dict) else None
        if not isinstance(videos, list) or not videos:
            raise PluginError('live/v1/01 无视频列表')
        pick = None
        for it in videos:
            if not isinstance(it, dict) or not it.get('url'):
                continue
            if pick is None:
                pick = it
            if it.get('rate') == '36p':
                pick = it
                break
        if pick is None:
            raise PluginError('live/v1/01 无可用地址')
        u = pick['url']
        return u if u.startswith('http') else aes_gcm_decrypt_b64(u, self.session_key)

    def app_secret(self):
        body = {'guid': aes_gcm_encrypt_b64('', self.session_key)}
        resp = self.client.post_json(LIVE_V1_02_URL,
                                     fresh_headers(self.identity.headers, VA, VA, None), body)
        status, _, value = response_json(resp)
        if not 200 <= status < 300:
            raise PluginError('live/v1/02 HTTP %s' % status)
        data = value.get('data') if isinstance(value, dict) else None
        enc = ''
        if isinstance(data, dict):
            enc = data.get('appSecret') or data.get('app_secret') or ''
        elif isinstance(data, str):
            enc = data
        if not enc:
            raise PluginError('live/v1/02 无 appSecret')
        return aes_gcm_decrypt_b64(enc, self.session_key)

    def vdn(self, live_url, secret):
        sign, rand = compute_vdn_code(secret, None)
        headers = fresh_headers(self.identity.headers, 'application/x-www-form-urlencoded', None, None)
        headers['APPID'] = AK
        headers['APPSIGN'] = sign
        headers['APPRANDOMSTR'] = rand
        resp = self.client.post_form(VDN_GETSTREAM_URL, headers,
                                     [('appcommon', build_vdn_appcommon(TV_VERSION)),
                                      ('url', live_url)])
        status, text, value = response_json(resp)
        if not 200 <= status < 300:
            raise PluginError('VDN HTTP %s' % status)
        if isinstance(value, dict):
            ok = value.get('succeed')
            ok = ok.strip('"') if isinstance(ok, str) else str(ok)
            if ok == '1' and isinstance(value.get('url'), str):
                hdrs = default_cctv_playback_headers(self.profile.android_id)
                hdrs['APPRANDOMSTR'] = rand
                hdrs['APPID'] = AK
                hdrs['APPSIGN'] = sign
                return {'urls': [value['url']], 'headers': hdrs, 'mode': 'device',
                        'defn': 'high'}
        raise PluginError('VDN 未返回地址: %s' % text[:160])


_DEVICE = {'sess': None, 'lock': threading.Lock(), 'last_error': '', 'fail_at': 0.0}
DEVICE_RETRY_COOLDOWN = 60.0


def device_session(refresh=False):
    with _DEVICE['lock']:
        s = _DEVICE['sess']
        now = time.time()
        if s is not None and not refresh and now - s.created_at < 3600:
            if now - s.last_heartbeat_at > 600:
                try:
                    _BG_POOL.submit(s.heartbeat)
                except Exception:
                    pass
            return s
        if not refresh and _DEVICE['fail_at'] and now - _DEVICE['fail_at'] < DEVICE_RETRY_COOLDOWN:
            raise PluginError('高码率暂不可用（%ds 后重试）: %s'
                              % (int(DEVICE_RETRY_COOLDOWN - (now - _DEVICE['fail_at'])),
                                 _DEVICE['last_error'][:60]))
        try:
            s = DeviceSession(DEVICE_JSON).bootstrap()
            _DEVICE['sess'] = s
            _DEVICE['last_error'] = ''
            log('设备身份就绪 guid=%s' % s.cloud_guid[:12])
            return s
        except Exception as e:  # noqa: BLE001
            _DEVICE['last_error'] = str(e)
            _DEVICE['fail_at'] = time.time()
            raise PluginError('高码率不可用: %s' % e)


def device_resolve(slug):
    sid = LIVE_IDS.get(slug)
    if not sid:
        raise PluginError('该频道无设备协议 ID')
    sess = device_session()
    url = sess.live_url(sid)
    secret = sess.app_secret()
    return sess.vdn(url, secret)


# ---------------------------------------------------------------------------
# JCE 时移（回看 + 短时缓存）
# ---------------------------------------------------------------------------
_JCE_CACHE = collections.OrderedDict()
_JCE_LOCK = threading.Lock()


def jce_playlist(slug, start, end, defn=None):
    meta = CHANNELS[slug]
    ck = (slug, int(start), int(end), defn or meta['defn'])
    now = time.time()
    with _JCE_LOCK:
        hit = _JCE_CACHE.get(ck)
        if hit and now - hit[0] < 60.0:
            _JCE_CACHE.move_to_end(ck)
            return hit[1], hit[2]
    url = jce_timeshift_url(meta['pid'], meta['sid'], int(start), int(end), defn or meta['defn'])
    try:
        status, _, _, raw, final_u, _, _ = _HTTP_POOL.request(
            'GET', url, headers={'User-Agent': UA}, timeout=15.0
        )
        if status != 200:
            raise PluginError('时移清单 HTTP %s' % status)
        text = raw.decode('utf-8', 'replace')
        with _JCE_LOCK:
            _JCE_CACHE[ck] = (now, text, final_u)
            while len(_JCE_CACHE) > 128:
                _JCE_CACHE.popitem(last=False)
        return text, final_u
    except Exception as e:  # noqa: BLE001
        raise PluginError('JCE 时移失败: %s' % e)


# ---------------------------------------------------------------------------
# TS 分片缓存（含 Single-Flight + 流式协同）+ 有界 _SEG 注册表
# ---------------------------------------------------------------------------
class TsCache(object):
    def __init__(self, max_mb=200, ttl=180, max_item_mb=20):
        self.max_bytes = max(0, int(max_mb * 1024 * 1024))
        self.max_item_bytes = min(self.max_bytes, int(max_item_mb * 1024 * 1024)) if self.max_bytes else 0
        self.ttl = ttl
        self.lock = threading.Lock()
        self.data = collections.OrderedDict()  # key -> (body, headers, exp)
        self.size = 0
        self.hits = 0
        self.misses = 0
        self.inflight = {}

    def has(self, key):
        with self.lock:
            it = self.data.get(key)
            return bool(it and time.time() <= it[2])

    def get(self, key):
        with self.lock:
            it = self.data.get(key)
            if not it or time.time() > it[2]:
                if it:
                    self.data.pop(key, None)
                    self.size -= len(it[0])
                self.misses += 1
                return None
            self.hits += 1
            self.data.move_to_end(key)
            return it[0], it[1]

    def put(self, key, body, headers):
        if not body or len(body) > self.max_item_bytes:
            return
        with self.lock:
            old = self.data.pop(key, None)
            if old is not None:
                self.size -= len(old[0])
            while self.size + len(body) > self.max_bytes and self.data:
                _, evicted = self.data.popitem(last=False)
                self.size -= len(evicted[0])
            self.data[key] = (body, headers, time.time() + self.ttl)
            self.size += len(body)

    def get_or_load(self, key, loader, timeout=25.0):
        hit = self.get(key)
        if hit is not None:
            return hit
        with self.lock:
            fut = self.inflight.get(key)
            owner = fut is None
            if owner:
                fut = Future()
                self.inflight[key] = fut
        if not owner:
            try:
                return fut.result(timeout=timeout)
            except FutureTimeout as e:
                raise PluginError('并发分片等待超时') from e
        try:
            body, hdrs = loader()
            if not body:
                raise PluginError('空分片')
            self.put(key, body, hdrs)
            fut.set_result((body, hdrs))
            return body, hdrs
        except BaseException as e:
            fut.set_exception(e)
            raise
        finally:
            with self.lock:
                if self.inflight.get(key) is fut:
                    self.inflight.pop(key, None)

    def try_claim_stream(self, key):
        with self.lock:
            it = self.data.get(key)
            if it and time.time() <= it[2]:
                self.hits += 1
                self.data.move_to_end(key)
                return (it[0], it[1]), False, None
            if it:
                self.data.pop(key, None)
                self.size -= len(it[0])
            self.misses += 1
            fut = self.inflight.get(key)
            if fut is None:
                fut = Future()
                self.inflight[key] = fut
                return None, True, fut
            return None, False, fut

    def finish_stream(self, key, fut, body=None, hdrs=None, exc=None):
        try:
            if exc is not None:
                fut.set_exception(exc)
            else:
                hdrs = hdrs or {'Content-Type': 'video/mp2t'}
                if body:
                    self.put(key, body, hdrs)
                fut.set_result((body or b'', hdrs))
        finally:
            with self.lock:
                if self.inflight.get(key) is fut:
                    self.inflight.pop(key, None)

    def stats(self):
        with self.lock:
            total = max(1, self.hits + self.misses)
            return {
                'count': len(self.data),
                'size_mb': round(self.size / 1048576.0, 2),
                'hits': self.hits,
                'misses': self.misses,
                'inflight': len(self.inflight),
                'hit_rate': '%.1f%%' % (self.hits * 100.0 / total),
            }


CACHE = TsCache(int(os.environ.get('YSP_CACHE_MB', '200')))
_SEG = collections.OrderedDict()
_SEG_LOCK = threading.Lock()
_NEXT_TOKEN_MAP = collections.OrderedDict()
MAX_SEG_ENTRIES = 5000


def _put_seg_meta(tok, info, next_tok=None):
    with _SEG_LOCK:
        _SEG[tok] = info
        _SEG.move_to_end(tok)
        while len(_SEG) > MAX_SEG_ENTRIES:
            _SEG.popitem(last=False)
        if next_tok:
            _NEXT_TOKEN_MAP[tok] = next_tok
            _NEXT_TOKEN_MAP.move_to_end(tok)
            while len(_NEXT_TOKEN_MAP) > MAX_SEG_ENTRIES:
                _NEXT_TOKEN_MAP.popitem(last=False)


def _get_seg_meta(tok):
    with _SEG_LOCK:
        return _SEG.get(tok), _NEXT_TOKEN_MAP.get(tok)


def fetch_playlist(url, headers=None, timeout=10.0):
    hdr = {'User-Agent': UA, 'Referer': 'https://live.cctv.cn/',
           'Accept': 'application/vnd.apple.mpegurl,*/*'}
    hdr.update({k: v for k, v in (headers or {}).items() if isinstance(v, str) and v})
    last = None
    for attempt in range(3):
        try:
            status, _, _, raw, final_u, _, _ = _HTTP_POOL.request('GET', url, headers=hdr, timeout=timeout)
            if status == 200:
                return raw.decode('utf-8', 'replace'), final_u
            last = 'HTTP %s' % status
        except Exception as e:  # noqa: BLE001
            last = e
        time.sleep(0.35 * (attempt + 1))
    raise PluginError('拉取清单失败: %s' % last)


def fetch_playlist_multi(urls, headers=None, timeout=10.0):
    """主备地址自动故障转移：按顺序尝试 urls，若返回主清单则自动追踪进入最高画质子清单。"""
    last_err = None
    for u in urls:
        try:
            pl, base = fetch_playlist(u, headers=headers, timeout=timeout)
            for _ in range(2):
                if '#EXT-X-STREAM-INF' not in pl:
                    break
                variants = []
                cur_bw = 0
                for ln in pl.splitlines():
                    s = ln.strip()
                    if s.startswith('#EXT-X-STREAM-INF:'):
                        m = re.search(r'BANDWIDTH=(\d+)', s)
                        cur_bw = int(m.group(1)) if m else 0
                    elif s and not s.startswith('#'):
                        variants.append((cur_bw, urllib.parse.urljoin(base, s)))
                        cur_bw = 0
                if not variants:
                    break
                variants.sort(key=lambda x: -x[0])
                pl, base = fetch_playlist(variants[0][1], headers=headers, timeout=timeout)
            return pl, base
        except Exception as e:  # noqa: BLE001
            last_err = e
            continue
    raise PluginError('全部候选线路均拉取失败: %s' % last_err)


def parse_segments(playlist, base):
    """返回 [(key_hint, dur, absolute_url)]，key_hint 用 PDT，缺失时用文件尾部标识或序号。"""
    segs, pdt, dur, idx = [], '', 6.0, 0
    for line in playlist.splitlines():
        s = line.strip()
        if s.startswith('#EXT-X-PROGRAM-DATE-TIME:'):
            pdt = s[len('#EXT-X-PROGRAM-DATE-TIME:'):]
        elif s.startswith('#EXTINF:'):
            try:
                dur = float(s[8:].split(',')[0])
            except ValueError:
                dur = 6.0
        elif s and not s.startswith('#'):
            abs_u = urllib.parse.urljoin(base, s)
            tail_name = urllib.parse.urlsplit(abs_u).path.rsplit('/', 1)[-1]
            key = pdt or tail_name or ('seq%d' % idx)
            segs.append((key, dur, abs_u))
            idx += 1
            pdt = ''
    return segs


def seg_token(slug, key):
    raw = ('%s|%s' % (slug, key)).encode()
    return base64.urlsafe_b64encode(hashlib.sha1(raw).digest()[:12]).decode().rstrip('=')


def _needs_segment_proxy(headers=None, force_proxy=False):
    """判断分片是否必须经过本机 /seg/ 代理：仅当显式开启 proxy 或携带 APPSIGN/UID 设备签名头时才代理分片。"""
    if force_proxy or PROXY_TS_DEFAULT:
        return True
    if not headers:
        return False
    upper_keys = {str(k).upper() for k in headers.keys() if headers.get(k)}
    return bool(upper_keys & {'APPSIGN', 'APPRANDOMSTR', 'APPID', 'UID', 'X-FINGERPRINT'})


def _absolutize_tag_uri(line, base):
    def _repl(m):
        u = m.group(1)
        if not u or u.startswith(('http://', 'https://', 'data:')):
            return m.group(0)
        return 'URI="%s"' % urllib.parse.urljoin(base, u)
    return re.sub(r'URI="([^"]+)"', _repl, line)


def rewrite_direct(playlist, base):
    """把相对分片地址与 URI 标签直接改写为上游 CDN 绝对地址，供 AVPlayer/CicadaPlayer 零跳直连播放。"""
    out = []
    for line in playlist.splitlines():
        s = line.strip()
        if not s:
            continue
        if s.startswith('#'):
            if 'URI="' in s:
                out.append(_absolutize_tag_uri(s, base))
            else:
                out.append(s)
        else:
            out.append(urllib.parse.urljoin(base, s))
    return '\n'.join(out)


def rewrite(playlist, base, origin, headers=None, slug='', token='', force_proxy=False):
    """智能改写分片地址：标准免签流直连 CDN 避免占满宿主 4 Worker；高码率签名流或指定 proxy=1 时走 /seg/ 代理。"""
    if not slug or not _needs_segment_proxy(headers, force_proxy=force_proxy):
        return rewrite_direct(playlist, base)
    segs = parse_segments(playlist, base)
    now = time.time()
    toks = [seg_token(slug, k) for k, _d, _u in segs]
    for idx, (k, _d, u) in enumerate(segs):
        tok = toks[idx]
        nxt_tok = toks[idx + 1] if idx + 1 < len(toks) else None
        _put_seg_meta(tok, {
            'url': u, 'headers': dict(headers or {}),
            'slug': slug, 'ts': now, 'key': k
        }, next_tok=nxt_tok)

    if toks and PROXY_TS_DEFAULT:
        _schedule_prefetch(toks[-1])

    tok_q = ('?token=' + urllib.parse.quote(token)) if token else ''
    out, i = [], 0
    for line in playlist.splitlines():
        s = line.strip()
        if not s:
            continue
        if s and not s.startswith('#'):
            tok = toks[i] if i < len(toks) else ''
            out.append(('%s/seg/%s.ts%s' % (origin, tok, tok_q)) if tok else urllib.parse.urljoin(base, s))
            i += 1
        elif 'URI="' in s:
            out.append(_absolutize_tag_uri(s, base))
        else:
            out.append(s)
    return '\n'.join(out)


def _seg_fetch(url, headers, timeout=20.0):
    hdr = {'User-Agent': UA, 'Referer': 'https://live.cctv.cn/'}
    hdr.update({k: v for k, v in (headers or {}).items() if isinstance(v, str) and v})
    status, _, resp_hdrs, body, _, _, _ = _HTTP_POOL.request('GET', url, headers=hdr, timeout=timeout)
    if status != 200:
        raise PluginError('分片 HTTP %s' % status)
    return body, (resp_hdrs.get('content-type') or 'video/mp2t')


def _seg_fetch_stream(url, headers, timeout=20.0):
    hdr = {'User-Agent': UA, 'Referer': 'https://live.cctv.cn/'}
    hdr.update({k: v for k, v in (headers or {}).items() if isinstance(v, str) and v})
    status, _, resp_hdrs, resp, _, cl, release_fn = _HTTP_POOL.request(
        'GET', url, headers=hdr, timeout=timeout, stream=True
    )
    if status != 200:
        if release_fn:
            release_fn(ok=False)
        raise PluginError('分片 HTTP %s' % status)
    ct = resp_hdrs.get('content-type') or 'video/mp2t'
    return resp, ct, cl, release_fn


def _schedule_prefetch(tok):
    if not tok or CACHE.has(tok):
        return
    try:
        _BG_POOL.submit(_prefetch_token, tok)
    except RuntimeError:
        pass


def _prefetch_token(tok):
    try:
        get_segment(tok)
    except Exception:
        pass


class StaleSegment(Exception):
    pass


# ---------------------------------------------------------------------------
# 直播清单缓存与异步滚动刷新
# ---------------------------------------------------------------------------
_LIVE_CACHE = {}
_LAST_GOOD = {}
_LIVE_LOCK = threading.Lock()
_CHANNEL_LOCKS = {}


def _parse_pl_interval(pl):
    m = re.search(r'#EXT-X-TARGETDURATION:(\d+)', pl or '')
    if not m:
        return 3.0
    return max(2.0, min(int(m.group(1)) * 0.5, 5.0))


def _bg_refresh_channel(slug, defn):
    key = (slug, defn)
    try:
        res = resolve_channel(slug, defn)
        pl, base = fetch_playlist_multi(res['urls'], res.get('headers'))
        now = time.time()
        entry = (pl, base, res.get('headers') or {})
        with _LIVE_LOCK:
            _LIVE_CACHE[key] = {
                'ts': now, 'entry': entry,
                'inflight': False, 'interval': _parse_pl_interval(pl)
            }
            _LAST_GOOD[slug] = (now, entry)
    except Exception:
        with _LIVE_LOCK:
            st = _LIVE_CACHE.get(key)
            if st:
                st['inflight'] = False


def refresh_channel_playlist(slug, force=False, defn=None):
    key = (slug, defn)
    now = time.time()
    with _LIVE_LOCK:
        hit = _LIVE_CACHE.get(key)
        ch_lock = _CHANNEL_LOCKS.setdefault(key, threading.Lock())
        if hit and not force:
            age = now - hit['ts']
            if age < hit['interval']:
                return hit['entry']
            if age < 12.0:
                if not hit['inflight']:
                    hit['inflight'] = True
                    try:
                        _BG_POOL.submit(_bg_refresh_channel, slug, defn)
                    except RuntimeError:
                        hit['inflight'] = False
                return hit['entry']

    with ch_lock:
        now = time.time()
        with _LIVE_LOCK:
            hit = _LIVE_CACHE.get(key)
            if hit and not force and now - hit['ts'] < hit['interval']:
                return hit['entry']
        try:
            res = resolve_channel(slug, defn)
            pl, base = fetch_playlist_multi(res['urls'], res.get('headers'))
            entry = (pl, base, res.get('headers') or {})
            now_ok = time.time()
            with _LIVE_LOCK:
                _LIVE_CACHE[key] = {
                    'ts': now_ok, 'entry': entry,
                    'inflight': False, 'interval': _parse_pl_interval(pl)
                }
                _LAST_GOOD[slug] = (now_ok, entry)
            return entry
        except Exception as e:  # noqa: BLE001
            with _LIVE_LOCK:
                lg = _LAST_GOOD.get(slug)
            if lg and time.time() - lg[0] < 90:
                log('解析失败，使用 90s 内的上次清单: %s (%s)' % (slug, e))
                return lg[1]
            raise


def _resign_and_find_seg(token, item):
    slug = item['slug']
    pl, base, hdrs = refresh_channel_playlist(slug, force=True)
    segs = parse_segments(pl, base)
    want = item.get('key')
    target = None
    for k, _d, u in segs:
        if want and k == want:
            target = u
            break
    if target is None and segs:
        target = segs[-1][2]
    if target is None:
        raise StaleSegment('重新签发后仍无可用分片')
    _put_seg_meta(token, {'url': target, 'headers': hdrs, 'slug': slug, 'ts': time.time(), 'key': want})
    return target, hdrs


def get_segment(token):
    """同步获取分片（含单飞锁 + 失效重签），供预取或 HEAD 请求调用。"""
    item, nxt_tok = _get_seg_meta(token)
    if nxt_tok:
        _schedule_prefetch(nxt_tok)
    if not item:
        hit = CACHE.get(token)
        if hit:
            return hit
        raise StaleSegment('未知分片')

    def _loader():
        try:
            body, ct = _seg_fetch(item['url'], item['headers'])
            return body, {'Content-Type': ct}
        except Exception as first_err:  # noqa: BLE001
            log('分片失败(%s)，重新签发 %s' % (first_err, item['slug']))
            target, hdrs = _resign_and_find_seg(token, item)
            body, ct = _seg_fetch(target, hdrs)
            return body, {'Content-Type': ct}

    return CACHE.get_or_load(token, _loader, timeout=25.0)


# ---------------------------------------------------------------------------
# EPG（并发拉取节目单）
# ---------------------------------------------------------------------------
_EPG = {'ts': 0.0, 'body': b'', 'lock': threading.Lock(), 'gen_lock': threading.Lock()}
CNTV_EPG = 'https://api.cntv.cn/epg/getEpgInfoByChannelNew'
CNTV_CHANNEL = {
    'cctv1': 'cctv1', 'cctv2': 'cctv2', 'cctv3': 'cctv3', 'cctv4': 'cctv4',
    'cctv5': 'cctv5', 'cctv6': 'cctv6', 'cctv7': 'cctv7', 'cctv8': 'cctv8',
    'cctv9': 'cctv9', 'cctv10': 'cctv10', 'cctv11': 'cctv11', 'cctv12': 'cctv12',
    'cctv13': 'cctv13', 'cctv14': 'cctv14', 'cctv15': 'cctv15', 'cctv16': 'cctv16',
    'cctv17': 'cctv17', 'cctv4k': 'cctv4k', 'cctv8k': 'cctv8k', 'cctv164k': 'cctv16',
    'cgtn': 'cgtn', 'cctv5p': 'cctv5p',
}


def _xml_time(ts):
    return time.strftime('%Y%m%d%H%M%S +0800', time.localtime(ts))


def _xml_escape(t):
    return (t or '').replace('&', '&amp;').replace('<', '&lt;').replace('>', '&gt;')


def cntv_programmes(slug, date_str):
    """央视网公开节目单，返回 [(start,end,title)]。"""
    code = CNTV_CHANNEL.get(slug)
    if not code:
        return []
    url = '%s?c=%s&serviceId=tvcctv&d=%s&t=json' % (CNTV_EPG, code, date_str)
    try:
        status, _, _, raw, _, _, _ = _HTTP_POOL.request('GET', url, headers={'User-Agent': UA}, timeout=10.0)
        if status != 200:
            return []
        data = json.loads(raw.decode('utf-8', 'replace')).get('data') or {}
        items = (data.get(code) or {}).get('list') or []
    except Exception:  # noqa: BLE001
        return []
    out = []
    for it in items:
        try:
            out.append((int(it['startTime']), int(it['endTime']), it.get('title') or ''))
        except (KeyError, ValueError, TypeError):
            continue
    return out


def upstream_programmes():
    """第三方 XMLTV 兜底（卫视等），按我们的 tvg-id 过滤。"""
    ids = set(TVG_IDS.values())
    for src in EPG_SOURCES:
        try:
            status, _, _, data, _, _, _ = _HTTP_POOL.request('GET', src, headers={'User-Agent': UA}, timeout=25.0)
            if status != 200:
                continue
            if data[:2] == b'\x1f\x8b':
                data = gzip.decompress(data)
            if b'<tv' not in data[:4096]:
                continue
        except Exception:  # noqa: BLE001
            continue
        out = []
        for m in re.finditer(r'<programme\b([^>]*)>(.*?)</programme>', data.decode('utf-8', 'replace'), re.S):
            attrs, inner = m.group(1), m.group(2)
            cid = re.search(r'channel="([^"]+)"', attrs)
            st = re.search(r'start="([^"]+)"', attrs)
            sp = re.search(r'stop="([^"]+)"', attrs)
            ti = re.search(r'<title[^>]*>(.*?)</title>', inner, re.S)
            if not (cid and st and sp and ti) or cid.group(1) not in ids:
                continue
            out.append((cid.group(1), st.group(1), sp.group(1), ti.group(1)))
        if out:
            return out
    return []


def epg_xml():
    with _EPG['lock']:
        if _EPG['body'] and time.time() - _EPG['ts'] < 1800:
            return _EPG['body']

    with _EPG['gen_lock']:
        with _EPG['lock']:
            if _EPG['body'] and time.time() - _EPG['ts'] < 1800:
                return _EPG['body']

        parts = ['<?xml version="1.0" encoding="UTF-8"?>',
                 '<tv generator-info-name="ysp-live-plugin %s">' % __version__]
        for slug in CHANNEL_ORDER:
            meta = CHANNELS[slug]
            cid = TVG_IDS.get(slug, slug.upper())
            canon_id = get_canonical_tvg_id(slug)
            names = [meta['name'], cid, canon_id, slug]
            seen_names = []
            for nm in names:
                if nm and nm not in seen_names:
                    seen_names.append(nm)
            dn_xml = ''.join('<display-name>%s</display-name>' % _xml_escape(nm) for nm in seen_names)
            parts.append('<channel id="%s">%s</channel>' % (_xml_escape(cid), dn_xml))

        today = time.strftime('%Y%m%d')
        today_start = int(time.mktime(time.strptime(today, '%Y%m%d')))
        covered = set()

        cntv_slugs = [s for s in CHANNEL_ORDER if s in CNTV_CHANNEL]
        with ThreadPoolExecutor(max_workers=2) as pool:
            fut_map = {pool.submit(cntv_programmes, slug, today): slug for slug in cntv_slugs}
            for fut in as_completed(fut_map):
                slug = fut_map[fut]
                progs = fut.result()
                if not progs:
                    continue
                covered.add(TVG_IDS.get(slug, slug.upper()))
                cid = _xml_escape(TVG_IDS.get(slug, slug.upper()))
                for st, et, title in progs:
                    if et <= today_start - 86400 or st >= today_start + 3 * 86400:
                        continue
                    parts.append('<programme start="%s" stop="%s" channel="%s"><title lang="zh">%s</title>'
                                 '<desc lang="zh">%s</desc></programme>'
                                 % (_xml_time(st), _xml_time(et), cid,
                                    _xml_escape(title), _xml_escape(CHANNELS[slug]['name'])))

        for cid, st, sp, title in upstream_programmes():
            if cid in covered:
                continue
            parts.append('<programme start="%s" stop="%s" channel="%s"><title lang="zh">%s</title></programme>'
                         % (st, sp, _xml_escape(cid), title))
        parts.append('</tv>')
        body = '\n'.join(parts).encode('utf-8')
        with _EPG['lock']:
            _EPG['body'] = body
            _EPG['ts'] = time.time()
        return body


# ---------------------------------------------------------------------------
# M3U
# ---------------------------------------------------------------------------
def m3u(origin, defn=None, token='', proxy_ts=False):
    tok_q = ('?token=' + urllib.parse.quote(token)) if token else ''
    lines = ['#EXTM3U url-tvg="%s/epg.xml%s" x-tvg-url="%s/epg.xml%s"' % (origin, tok_q, origin, tok_q)]
    for slug in CHANNEL_ORDER:
        meta = CHANNELS[slug]
        q_parts = []
        if defn:
            q_parts.append('defn=%s' % defn)
        if proxy_ts:
            q_parts.append('proxy=1')
        if token:
            q_parts.append('token=%s' % urllib.parse.quote(token))
        q = ('?' + '&'.join(q_parts)) if q_parts else ''
        catchup_tok = ('&token=' + urllib.parse.quote(token)) if token else ''
        if proxy_ts:
            catchup_tok += '&proxy=1'
        attr = ('#EXTINF:-1 tvg-id="%s" tvg-name="%s" tvg-logo="%s" group-title="%s" '
                'catchup="default" catchup-days="7" catchup-source="%s/live/%s.m3u8?start=${start}&end=${end}%s"'
                % (TVG_IDS.get(slug, slug.upper()), meta['name'],
                   get_channel_logo(slug), get_channel_group(slug), origin, slug, catchup_tok))
        lines.append(attr + ',' + meta['name'])
        lines.append('%s/live/%s.m3u8%s' % (origin, slug, q))
    return '\n'.join(lines) + '\n'


def parse_ts(v):
    if not v:
        return 0
    v = str(v).strip()
    if v.startswith('${(b)') and v.endswith('}'):
        v = v[5:-1].strip()
    elif v.startswith('${') and v.endswith('}'):
        v = v[2:-1].strip()
    elif v.startswith('{') and v.endswith('}'):
        v = v[1:-1].strip()
    if v.isdigit():
        n = int(v)
        return n // 1000 if n > 10 ** 12 else n
    for fmt in ('%Y%m%d%H%M%S', '%Y-%m-%dT%H:%M:%S', '%Y-%m-%d %H:%M:%S'):
        try:
            return int(time.mktime(time.strptime(v[:19], fmt)))
        except ValueError:
            continue
    return 0


# ---------------------------------------------------------------------------
# HTTP 服务
# ---------------------------------------------------------------------------
def resolve_channel(slug, defn=None, allow_device=True):
    want_high = (not NO_4K_DEFAULT) and allow_device and (slug in HIGH_RATE or defn == '4k')
    if want_high:
        try:
            return device_resolve(slug)
        except PluginError as e:
            log('高码率失败，回退 1080p: %s' % e)
    return bk_resolve(slug, defn)


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
    server_version = 'ysp-live-plugin/' + __version__
    protocol_version = 'HTTP/1.1'

    def setup(self):
        super().setup()
        try:
            self.connection.settimeout(20.0)
        except Exception:
            pass

    def log_message(self, fmt, *args):
        if not QUIET and not self.path.startswith('/seg/'):
            log(fmt % args)

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

    def _origin(self):
        return 'http://%s' % (self.headers.get('Host') or ('127.0.0.1:%d' % PORT))

    def _check_auth(self, qs):
        if not AUTH_TOKEN:
            return True
        got = (qs.get('token', [''])[0] or self.headers.get('X-YSP-Token', '')).strip()
        return secrets.compare_digest(got, AUTH_TOKEN)

    def do_HEAD(self):
        self.do_GET(head_only=True)

    def do_GET(self, head_only=False):
        p = urllib.parse.urlsplit(self.path)
        path = p.path.rstrip('/') or '/'
        qs = urllib.parse.parse_qs(p.query)
        defn = (qs.get('defn') or [None])[0]
        try:
            if path in ('/', '/index.html'):
                return self._send(200, self._index(), 'text/html; charset=utf-8', head_only=head_only)

            if path == '/health':
                return self._send(200, json.dumps({
                    'ok': True,
                    'version': __version__,
                    'uptime_sec': int(time.time() - START_TIME),
                    'channels': len(CHANNEL_ORDER),
                    'device': bool(_DEVICE['sess']),
                    'device_error': _DEVICE['last_error'],
                    'http_pool': _HTTP_POOL.stats(),
                    'cache': CACHE.stats(),
                    'seg_registry': len(_SEG),
                }, ensure_ascii=False, indent=2), 'application/json; charset=utf-8', head_only=head_only)

            if path == '/diag':
                return self._send(200, self._diag(), 'text/plain; charset=utf-8', head_only=head_only)

            if path == '/logs':
                with _log_lock:
                    lines = list(global_log_ring)[-80:]
                return self._send(200, '\n'.join(lines) + '\n', head_only=head_only)

            if not self._check_auth(qs):
                return self._send(401, 'unauthorized\n', head_only=head_only)

            if path in ('/all.m3u', '/all.m3u8', '/m3u', '/playlist.m3u', '/ysp.m3u'):
                use_proxy = PROXY_TS_DEFAULT or (qs.get('proxy', [''])[0] == '1')
                return self._send(200, m3u(self._origin(), defn, token=AUTH_TOKEN, proxy_ts=use_proxy),
                                  'application/vnd.apple.mpegurl; charset=utf-8', head_only=head_only)

            if path == '/programs':
                slug = normalize_slug((qs.get('channel') or ['cctv1'])[0])
                day = (qs.get('date') or [time.strftime('%Y%m%d')])[0]
                progs = cntv_programmes(slug, day)
                now = int(time.time())
                items = [{'start': s0, 'end': e0, 'title': t,
                          'startText': time.strftime('%H:%M', time.localtime(s0)),
                          'endText': time.strftime('%H:%M', time.localtime(e0)),
                          'live': s0 <= now < e0} for s0, e0, t in progs]
                body = json.dumps({'channel': slug, 'name': CHANNELS[slug]['name'],
                                   'date': day, 'programs': items}, ensure_ascii=False)
                return self._send(200, body, 'application/json; charset=utf-8', head_only=head_only)

            if path == '/epg.xml':
                return self._send(200, epg_xml(), 'application/xml; charset=utf-8', head_only=head_only)

            if path.startswith('/seg/'):
                key = path[len('/seg/'):]
                key = key[:-3] if key.endswith('.ts') else key
                return self._serve_segment(key, head_only=head_only)

            if path.startswith('/live/'):
                return self._live(path[len('/live/'):], qs, defn, head_only=head_only)

            if path.endswith('.m3u8') and len(path) > 6 and '/' not in path[1:]:
                return self._live(path[1:], qs, defn, head_only=head_only)

            return self._send(404, b'not found\n', head_only=head_only)
        except PluginError as e:
            return self._send(502, str(e), head_only=head_only)
        except StaleSegment as e:
            return self._send(404, str(e), head_only=head_only)
        except Exception as e:  # noqa: BLE001
            log('500 %s' % e)
            return self._send(500, '内部错误: %s' % e, head_only=head_only)

    def _serve_segment(self, token, head_only=False):
        item, nxt_tok = _get_seg_meta(token)
        if nxt_tok and not head_only:
            _schedule_prefetch(nxt_tok)

        if head_only:
            body, hdrs = get_segment(token)
            return self._send(200, body, hdrs.get('Content-Type', 'video/mp2t'),
                              {'Cache-Control': 'max-age=30'}, head_only=True)

        hit, is_owner, fut = CACHE.try_claim_stream(token)
        if hit is not None:
            body, hdrs = hit
            return self._send(200, body, hdrs.get('Content-Type', 'video/mp2t'),
                              {'Cache-Control': 'max-age=30'})
        if not is_owner:
            try:
                body, hdrs = fut.result(timeout=25.0)
            except FutureTimeout as e:
                raise PluginError('等待并发分片超时') from e
            return self._send(200, body, hdrs.get('Content-Type', 'video/mp2t'),
                              {'Cache-Control': 'max-age=30'})

        if not item:
            err = StaleSegment('未知分片')
            CACHE.finish_stream(token, fut, exc=err)
            raise err

        resp = None
        release_fn = None
        buf = bytearray()
        client_alive = True
        try:
            try:
                resp, ct, cl, release_fn = _seg_fetch_stream(item['url'], item['headers'])
            except Exception as first_err:
                log('分片流打开失败(%s)，重新签发 %s' % (first_err, item['slug']))
                target, hdrs = _resign_and_find_seg(token, item)
                resp, ct, cl, release_fn = _seg_fetch_stream(target, hdrs)

            self.send_response(200)
            self.send_header('Content-Type', ct)
            self.send_header('Cache-Control', 'max-age=30')
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
                    if len(buf) + len(chunk) <= CACHE.max_item_bytes:
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
            CACHE.finish_stream(token, fut, body=data, hdrs={'Content-Type': ct})
        except BaseException as e:
            if release_fn:
                release_fn(ok=False)
            CACHE.finish_stream(token, fut, exc=e)
            if client_alive:
                raise

    def _live(self, name, qs, defn, head_only=False):
        slug = name[:-5] if name.endswith('.m3u8') else name
        slug = normalize_slug(slug)
        start = parse_ts((qs.get('start') or [''])[0])
        end = parse_ts((qs.get('end') or [''])[0])
        force = 'refresh=1' in urllib.parse.urlsplit(self.path).query
        if start and end:
            if end <= start:
                raise PluginError('时间窗口无效')
            pl, base = jce_playlist(slug, start, end, defn)
            if qs.get('direct', [''])[0] == '1':
                self.send_response(302)
                self.send_header('Location', base)
                self.send_header('Content-Length', '0')
                self.send_header('Access-Control-Allow-Origin', '*')
                self.end_headers()
                return
            force_proxy = (qs.get('proxy', [''])[0] == '1')
            body = rewrite(pl, base, self._origin(), {'Referer': 'https://live.cctv.cn/'}, slug, token=AUTH_TOKEN, force_proxy=force_proxy)
        else:
            force_proxy = (qs.get('proxy', [''])[0] == '1')
            pl, base, hdrs = refresh_channel_playlist(slug, force=force, defn=defn)
            if qs.get('direct', [''])[0] == '1':
                self.send_response(302)
                self.send_header('Location', base)
                self.send_header('Content-Length', '0')
                self.send_header('Access-Control-Allow-Origin', '*')
                self.end_headers()
                return
            body = rewrite(pl, base, self._origin(), hdrs, slug, token=AUTH_TOKEN, force_proxy=force_proxy)
        return self._send(200, body,
                          'application/vnd.apple.mpegurl; charset=utf-8',
                          {'Cache-Control': 'no-store'}, head_only=head_only)

    def _diag(self):
        now = time.time()
        ps = _HTTP_POOL.stats()
        cs = CACHE.stats()
        sess = _DEVICE['sess']
        dev_str = ('就绪 guid=%s 存活=%ds' % (sess.cloud_guid[:12], int(now - sess.created_at))
                   if sess else ('未就绪 (%s)' % (_DEVICE['last_error'] or '按需初始化')))
        out = [
            '=' * 56,
            'ysp-live-plugin %s 诊断报告（运行 %ds）' % (__version__, int(now - START_TIME)),
            '=' * 56,
            '4K 设备会话: %s' % dev_str,
            'HTTP 连接池: 空闲=%d 复用=%d 新建=%d' % (ps['idle'], ps['reused'], ps['created']),
            'TS 分片缓存: 条目=%d 占用=%sMB 命中=%d 未中=%d 单飞=%d 命中率=%s'
            % (cs['count'], cs['size_mb'], cs['hits'], cs['misses'], cs['inflight'], cs['hit_rate']),
            '分片注册表: %d / %d 条' % (len(_SEG), MAX_SEG_ENTRIES),
            '--- 活跃频道缓存 (%d) ---' % len(_LIVE_CACHE),
        ]
        with _LIVE_LOCK:
            for (slug, df), info in list(_LIVE_CACHE.items())[:40]:
                out.append('%-12s defn=%-5s 窗口=%ds前 间隔=%.1fs %s' % (
                    slug, df or 'auto', int(now - info['ts']), info['interval'], info['entry'][1][:65]))
        return '\n'.join(out) + '\n'

    def _index(self):
        tok_q = ('?token=' + urllib.parse.quote(AUTH_TOKEN)) if AUTH_TOKEN else ''
        rows = ''.join('<li><a href="/live/%s.m3u8%s">%s</a> <small>%s</small></li>'
                       % (s, tok_q, CHANNELS[s]['name'], s) for s in CHANNEL_ORDER)
        return ('<!doctype html><meta charset="utf-8"><title>ysp</title>'
                '<h1>央视频直播源插件 v%s</h1><p>订阅：<a href="/all.m3u%s">/all.m3u</a> · '
                '节目单：<a href="/epg.xml%s">/epg.xml</a> · <a href="/health">/health</a> · '
                '<a href="/diag">/diag</a></p>'
                '<ul>%s</ul>' % (__version__, tok_q, tok_q, rows))


def normalize_slug(raw):
    s = (raw or '').strip().strip('/').lower()
    if s.endswith('.m3u8'):
        s = s[:-5]
    s = ALIAS_MAP.get(s, s)
    if s in ('cctv16-4k', 'cctv16_4k'):
        s = 'cctv164k'
    if s not in CHANNELS:
        raise PluginError('未知频道: %s' % raw)
    return s


def stop_server():
    """CCTVHost 沙箱协作式停止钩子：立即中断后台线程、释放连接池并关闭 HTTP Server。"""
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


def _warmup_worker():
    if _STOP_EVENT.wait(1.5):
        return
    if not NO_4K_DEFAULT and not _STOP_EVENT.is_set():
        try:
            device_session()
        except Exception:
            pass


def serve(port, bind):
    _STOP_EVENT.clear()
    _builtins._cctvhost_stop_service = stop_server
    _builtins._ysp_stop_server = stop_server
    httpd = QuietThreadingHTTPServer((bind, port), Handler)
    httpd.daemon_threads = True
    with _ACTIVE_SERVERS_LOCK:
        _ACTIVE_SERVERS.append(httpd)
    if not NO_4K_DEFAULT:
        threading.Thread(target=_warmup_worker, daemon=True, name='ysp-warmup').start()
    log('v%s 已启动 http://%s:%d/all.m3u' % (__version__, bind, port))
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
    ap = argparse.ArgumentParser(description='央视频直播源插件 v%s' % __version__)
    ap.add_argument('--list', action='store_true')
    ap.add_argument('--url', metavar='CHANNEL')
    ap.add_argument('--check', metavar='CHANNEL')
    ap.add_argument('--m3u', metavar='FILE')
    ap.add_argument('--defn')
    ap.add_argument('--token', default='', help='可选访问鉴权 Token')
    ap.add_argument('--high', action='store_true', help='--url/--check 时走高码率设备协议')
    ap.add_argument('--no-4k', action='store_true', help='禁用 4K/8K 设备协议，全部走免注册 bkliveinfo')
    ap.add_argument('--no-engine', action='store_true', help='兼容宿主启动参数')
    ap.add_argument('--proxy-ts', action='store_true', help='强制将全部 TS 分片改写为本机 /seg/ 代理')
    ap.add_argument('--data-dir', default='', help='持久化数据目录（兼容 CCTVHost）')
    ap.add_argument('--cache-mb', type=int, default=None, help='TS 分片内存缓存上限 MB')
    ap.add_argument('--links-per-device', type=int, default=4, help='兼容宿主启动参数')
    ap.add_argument('--zap-debounce', type=float, default=1.2, help='兼容宿主启动参数')
    ap.add_argument('--stable-playback', action='store_true', help='兼容宿主启动参数')
    ap.add_argument('--serve', action='store_true')
    ap.add_argument('port', nargs='?', type=int, default=None,
                    help='监听端口（默认 18768，兼容 CCTVHost / Minis 服务）')
    ap.add_argument('--port', dest='port_opt', type=int, default=None)
    ap.add_argument('--bind', default=os.environ.get('YSP_BIND', '127.0.0.1'))
    ap.add_argument('--lan', action='store_true', help='绑定 0.0.0.0 供局域网访问')
    ap.add_argument('--timeout', type=float, default=10.0)
    ap.add_argument('-q', '--quiet', action='store_true')
    args, _unknown = ap.parse_known_args(argv)

    global QUIET, PORT, AUTH_TOKEN, DATA_DIR, DEVICE_JSON, PROXY_TS_DEFAULT, NO_4K_DEFAULT, CACHE
    QUIET = args.quiet
    if args.token:
        AUTH_TOKEN = args.token.strip()
    if args.proxy_ts:
        PROXY_TS_DEFAULT = True
    if args.no_4k:
        NO_4K_DEFAULT = True
    if args.data_dir or os.environ.get('CCTVHOST_DATA_DIR'):
        DATA_DIR = _resolve_data_dir(args.data_dir)
        if not os.environ.get('YSP_DEVICE_JSON'):
            DEVICE_JSON = os.path.join(DATA_DIR, 'ysp-device.json')
    if args.cache_mb is not None:
        CACHE = TsCache(max(0, int(args.cache_mb)))
    env_port, env_name = None, ''
    for name in ('CCTVHOST_PORT', 'YSP_PORT', 'PORT', 'SERVER_PORT', 'MINIS_PORT', 'HTTP_PORT'):
        v = os.environ.get(name)
        if v and v.strip().isdigit():
            env_port, env_name = int(v.strip()), name
            break
    PORT = args.port_opt or args.port or env_port or 18768
    if args.lan and args.bind in ('127.0.0.1', 'localhost', ''):
        args.bind = '0.0.0.0'
    if not QUIET:
        src = ('--port' if args.port_opt else '位置参数' if args.port
               else ('环境变量 %s' % env_name if env_name else '默认值'))
        sys.stderr.write('[%s] 监听端口 %d（来源：%s）绑定 %s\n'
                         % (time.strftime('%H:%M:%S'), PORT, src, args.bind))
    args.port = PORT

    if args.list:
        for s in CHANNEL_ORDER:
            m = CHANNELS[s]
            print('%-12s %-18s sid=%s pid=%s%s' % (s, m['name'], m['sid'], m['pid'],
                                                   ' [高码率]' if s in HIGH_RATE else ''))
        return 0

    if args.url:
        slug = normalize_slug(args.url)
        try:
            res = device_resolve(slug) if args.high else resolve_channel(slug, args.defn)
        except PluginError as e:
            print('ERROR: %s' % e, file=sys.stderr)
            return 2
        print(res['urls'][0])
        for u in res['urls'][1:]:
            print('#备用 ' + u)
        return 0

    if args.check:
        targets = CHANNEL_ORDER if args.check == 'all' else [normalize_slug(x) for x in args.check.split(',') if x.strip()]
        bad = 0
        for slug in targets:
            try:
                res = resolve_channel(slug, args.defn, allow_device=args.high or slug in HIGH_RATE)
                pl, _ = fetch_playlist_multi(res['urls'], res.get('headers'))
                ok = pl.lstrip().startswith('#EXTM3U')
                note = '%s 分片 %d' % (res['mode'], len([l for l in pl.splitlines() if l and not l.startswith('#')]))
            except Exception as e:  # noqa: BLE001
                ok, note = False, str(e)[:90]
            print('%-12s %-18s %s  %s' % (slug, CHANNELS[slug]['name'], 'OK ' if ok else 'FAIL', note), flush=True)
            bad += 0 if ok else 1
            time.sleep(0.1)
        print('合计 %d，失败 %d' % (len(targets), bad))
        return 1 if bad else 0

    if args.m3u:
        origin = 'http://127.0.0.1:%d' % args.port
        with open(args.m3u, 'w', encoding='utf-8') as f:
            f.write(m3u(origin, args.defn, token=AUTH_TOKEN))
        print('已写入 %s（%d 频道）' % (args.m3u, len(CHANNEL_ORDER)))
        return 0

    serve(args.port, args.bind)
    return 0


if __name__ == '__main__':
    sys.exit(main())
