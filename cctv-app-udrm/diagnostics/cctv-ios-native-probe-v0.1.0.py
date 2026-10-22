#!/usr/bin/env python3
"""Read-only APTV native capability probe; no SDK/media/license downloads.

Uses public dyld APIs to report selected loaded image basenames and checks
already-loaded public C symbols. A loaded component does not prove permission
or a supported integration API. No app paths, account data or memory dumps.
"""
import argparse
import ctypes
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, HTTPServer
import json
import os
import platform
import sys

VERSION='0.1.0'
PORT=18771
GROUPS={
 'vendor_candidates':('kooplayer','cctv','cntv','udrm'),
 'native_emulator_candidates':('unicorn',),
 'system_media':('avfoundation','videotoolbox','coremedia'),
 'javascript':('javascriptcore','webkit'),
 'other_players':('mobilevlc','libavcodec','libavformat','ffmpeg','ijkplayer'),
}
PUBLIC_SYMBOLS={
 'unicorn_c_api':('uc_version','uc_open','uc_emu_start','uc_mem_read','uc_mem_write','uc_ctl'),
 'jscore_c_api':('JSGlobalContextCreate','JSEvaluateScript','JSObjectGetTypedArrayBytesPtr'),
}

def _loaded_images(process,limit=4096):
    count=process._dyld_image_count
    name=process._dyld_get_image_name
    count.argtypes=[];count.restype=ctypes.c_uint32
    name.argtypes=[ctypes.c_uint32];name.restype=ctypes.c_char_p
    total=int(count());names=set()
    for index in range(min(total,limit)):
        raw=name(index)
        if raw:
            # Only matched basenames leave this function; never return paths.
            base=os.path.basename(raw.decode('utf-8','replace'))
            if any(token in base.lower() for tokens in GROUPS.values() for token in tokens):
                names.add(base)
    return sorted(names),total,total>limit

def host_context(context):
    tokens=('native','sdk','plugin','framework','capabilit','player','bridge','version')
    if context is None:return {'present':False,'type':None,'capability_names':[]}
    names=dict.keys(context) if isinstance(context,dict) else type(context).__dict__.keys()
    selected=sorted(str(name) for name in names if isinstance(name,str) and not name.startswith('_') and any(token in name.lower() for token in tokens))
    return {'present':True,'type':type(context).__name__,'capability_names':selected[:64]}


def collect(context=None):
    report={'probe_version':VERSION,'observed_at_utc':datetime.now(timezone.utc).isoformat(),
        'platform':sys.platform,'hardware_machine':platform.machine(),
        'process_pointer_bits':ctypes.sizeof(ctypes.c_void_p)*8,
        'python_version':'.'.join(map(str,sys.version_info[:3])),
        'no_sdk_download':True,'no_media_requests':True,'no_license_requests':True,
        'no_external_process':True,'loaded_images_supported':False,
        'matching_loaded_components':{key:[] for key in GROUPS},
        'public_symbols':{},'native_unicorn_api_observed':False,
        'official_ios_sdk_verified':False,'aptv_plugin_api_verified':False,
        'integration_state':'unverified','host_context':host_context(context),
        'limits':['Loaded images describe only this process at this time.',
          'Symbol lookup covers already-visible global exports only.',
          'Missing loaded image does not prove a component is absent from the app bundle.',
          'Image names or symbol presence do not prove SDK compatibility, licensing, plugin support or playback.']}
    if sys.platform not in ('darwin','ios'):
        report['diagnostic']='Requires iPhone/iPad APTV for relevant native observations.'
        return report
    try:process=ctypes.CDLL(None)
    except (OSError,AttributeError):
        report['diagnostic']='Process symbol lookup unavailable.'
        return report
    for group,symbols in PUBLIC_SYMBOLS.items():
        report['public_symbols'][group]={symbol:hasattr(process,symbol) for symbol in symbols}
    report['native_unicorn_api_observed']=all(report['public_symbols']['unicorn_c_api'].values())
    try:
        names,total,truncated=_loaded_images(process)
        report.update(loaded_images_supported=True,loaded_image_count=total,scan_truncated=truncated)
        report['matching_loaded_components']={key:[name for name in names if any(t in name.lower() for t in tokens)] for key,tokens in GROUPS.items()}
    except (AttributeError,OSError,ValueError):
        report['diagnostic']='Public loaded-image API unavailable; symbol observations retained.'
    if report['matching_loaded_components']['vendor_candidates']:
        report['integration_state']='vendor_component_candidate_requires_official_api'
    elif report['native_unicorn_api_observed']:
        report['integration_state']='native_emulator_api_candidate_requires_validation'
    else:report['integration_state']='no_native_backend_observed'
    return report

class ProbeServer(HTTPServer):
    allow_reuse_address=True
    def get_request(self):
        request,address=super().get_request();request.settimeout(5);return request,address

class Handler(BaseHTTPRequestHandler):
    def do_HEAD(self):self._serve(True)
    def do_GET(self):self._serve(False)
    def _serve(self,head):
        if self.path not in ('/','/status'):
            code=404;body=b'Not found';ctype='text/plain'
        else:
            code=200;body=json.dumps(collect(getattr(self.server,'probe_context',None)),ensure_ascii=False,indent=2).encode();ctype='application/json; charset=utf-8'
        self.send_response(code);self.send_header('Content-Type',ctype)
        self.send_header('Content-Length',str(len(body)));self.send_header('Cache-Control','no-store');self.end_headers()
        if not head:
            try:self.wfile.write(body)
            except (BrokenPipeError,ConnectionResetError):pass
    def log_message(self,*args):pass

def main(argv=None,context=None):
    parser=argparse.ArgumentParser(description='APTV只读原生能力检测；不提供播放订阅')
    parser.add_argument('--port',type=int,default=PORT)
    parser.add_argument('--once',action='store_true')
    args=parser.parse_args(argv)
    if not 1<=args.port<=65535:parser.error('Invalid port')
    if args.once:
        print(json.dumps(collect(context),ensure_ascii=False,indent=2),flush=True);return
    report=collect(context);print('APTV只读原生检测 '+VERSION+'；结果 http://127.0.0.1:'+str(args.port)+'/status',flush=True)
    print(json.dumps(report,ensure_ascii=False),flush=True)
    server=ProbeServer(('127.0.0.1',args.port),Handler);server.probe_context=context
    try:server.serve_forever(poll_interval=.25)
    except KeyboardInterrupt:pass
    finally:server.server_close()

def start(ctx=None):main([],context=ctx)
if __name__=='__main__':main()
