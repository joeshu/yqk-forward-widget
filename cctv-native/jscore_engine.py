"""In-process system JavaScriptCore host. No subprocess or Python callbacks.

The official SDK is downloaded unchanged and hash checked. Browser interfaces
are supplied by jscore-host.js and pinned fake-indexeddb, not a source switch.
"""
import ctypes as c
import threading

APPLE_FRAMEWORK = '/System/Library/Frameworks/JavaScriptCore.framework/JavaScriptCore'


class JSContext:
    def __init__(self, library_path=APPLE_FRAMEWORK):
        self.owner = threading.get_ident()
        self.context = None
        try:
            self.library = c.CDLL(library_path)
            p = c.c_void_p
            signatures = [
                ('JSGlobalContextCreate', p, [p]),
                ('JSGlobalContextRelease', None, [p]),
                ('JSContextGetGroup', p, [p]),
                ('JSContextGroupSetExecutionTimeLimit', None, [p, c.c_double, p, p]),
                ('JSContextGroupClearExecutionTimeLimit', None, [p]),
                ('JSStringCreateWithUTF8CString', p, [c.c_char_p]),
                ('JSStringRelease', None, [p]),
                ('JSEvaluateScript', p, [p, p, p, p, c.c_int, c.POINTER(p)]),
                ('JSValueToStringCopy', p, [p, p, c.POINTER(p)]),
                ('JSValueToObject', p, [p, p, c.POINTER(p)]),
                ('JSStringGetMaximumUTF8CStringSize', c.c_size_t, [p]),
                ('JSStringGetUTF8CString', c.c_size_t, [p, p, c.c_size_t]),
            ]
            for name, result, arguments in signatures:
                function = getattr(self.library, name)
                function.restype, function.argtypes = result, arguments
            self.buffer_api = True
            for name, result in (('JSObjectGetTypedArrayBytesPtr',p),
                                 ('JSObjectGetTypedArrayByteLength',c.c_size_t)):
                try:
                    function = getattr(self.library,name)
                    function.restype, function.argtypes = result, [p,p,c.POINTER(p)]
                except AttributeError:
                    self.buffer_api = False
            self.context = self.library.JSGlobalContextCreate(None)
            if not self.context:
                raise NativeError('jscore-context-creation-failed')
            self.group = self.library.JSContextGetGroup(self.context)
        except (ImportError, OSError, AttributeError):
            raise NativeError('jscore-framework-or-time-limit-unavailable') from None

    def evaluate(self, script, timeout=15, *, _string_result=True):
        if threading.get_ident() != self.owner or not self.context:
            raise NativeError('jscore-wrong-thread-or-closed')
        j = self.library
        source = output = None
        # WebKit's C API specifies NULL callback means unconditional termination.
        # No CFUNCTYPE trampoline or executable callback allocation is needed.
        j.JSContextGroupSetExecutionTimeLimit(self.group, timeout, None, None)
        try:
            source = j.JSStringCreateWithUTF8CString(script.encode('utf-8'))
            if not source:
                raise NativeError('jscore-source-creation-failed')
            exception = c.c_void_p()
            value = j.JSEvaluateScript(self.context, source, None, None, 1, c.byref(exception))
            if exception.value or not value:
                raise NativeError('jscore-script-failed-or-timed-out')
            if not _string_result:
                return None
            output = j.JSValueToStringCopy(self.context, value, c.byref(exception))
            if exception.value or not output:
                raise NativeError('jscore-result-conversion-failed')
            size = j.JSStringGetMaximumUTF8CStringSize(output)
            if not 1 <= size <= 80*1024*1024:
                raise NativeError('jscore-result-too-large')
            buffer = c.create_string_buffer(size)
            if not j.JSStringGetUTF8CString(output, buffer, size):
                raise NativeError('jscore-result-copy-failed')
            return buffer.value.decode('utf-8')
        finally:
            if output:
                j.JSStringRelease(output)
            if source:
                j.JSStringRelease(source)
            j.JSContextGroupClearExecutionTimeLimit(self.group)

    def execute(self, script, timeout=15):
        # Preserve each script/microtask turn, but avoid converting unused
        # values (usually undefined) to strings through several native calls.
        return self.evaluate(script, timeout, _string_result=False)

    def _media_reference(self, expression):
        if threading.get_ident() != self.owner or not self.context:
            raise NativeError('jscore-wrong-thread-or-closed')
        j = self.library
        source = None
        j.JSContextGroupSetExecutionTimeLimit(self.group,15,None,None)
        try:
            source = j.JSStringCreateWithUTF8CString(expression.encode('ascii'))
            if not source:
                raise NativeError('jscore-source-creation-failed')
            exception = c.c_void_p()
            value = j.JSEvaluateScript(self.context,source,None,None,1,c.byref(exception))
            if exception.value or not value:
                raise NativeError('jscore-media-buffer-failed')
            # The object stays rooted in __mediaInput/__mediaOutput, not only
            # in an unprotected native JSValueRef, during subsequent API calls.
            obj = j.JSValueToObject(self.context,value,c.byref(exception))
            if exception.value or not obj:
                raise NativeError('jscore-media-buffer-object-failed')
            return obj
        finally:
            if source:
                j.JSStringRelease(source)
            j.JSContextGroupClearExecutionTimeLimit(self.group)

    def put_media(self, data):
        if not self.buffer_api or not 0 < len(data) <= 16*1024*1024:
            raise NativeError('jscore-media-buffer-invalid')
        value = self._media_reference('__mediaInput=new Uint8Array('+str(len(data))+')')
        exception = c.c_void_p()
        pointer = self.library.JSObjectGetTypedArrayBytesPtr(self.context,value,c.byref(exception))
        if exception.value or not pointer:
            raise NativeError('jscore-media-buffer-pointer-failed')
        # WebKit pointers are valid until the next JSC API call. Copy now;
        # never retain the pointer across evaluate/GC or other API calls.
        c.memmove(pointer,data,len(data))

    def read_media(self, limit):
        value = self._media_reference('__mediaOutput')
        exception = c.c_void_p()
        size = self.library.JSObjectGetTypedArrayByteLength(self.context,value,c.byref(exception))
        if exception.value or not 0 < size <= limit:
            raise NativeError('jscore-media-buffer-length-invalid')
        pointer = self.library.JSObjectGetTypedArrayBytesPtr(self.context,value,c.byref(exception))
        if exception.value or not pointer:
            raise NativeError('jscore-media-buffer-pointer-failed')
        return c.string_at(pointer,size)

    def close(self):
        if threading.get_ident() != self.owner:
            # Channel's worker owns the VM and releases it in its finally block.
            return
        if self.context:
            self.library.JSGlobalContextRelease(self.context)
            self.context = None


_RUNTIME_MEMORY = None
_RUNTIME_LOCK = threading.Lock()


def load_runtime(cache_dir=None):
    """Memory is the default; disk is optional and never required for playback."""
    global _RUNTIME_MEMORY
    with _RUNTIME_LOCK:
        if _RUNTIME_MEMORY is not None:
            return _RUNTIME_MEMORY
        raw = b''
        runtime = None
        if cache_dir:
            try:
                root = Path(cache_dir).expanduser()
                runtime = root / ('runtime-'+RUNTIME_SHA[:12]+'.js')
                if runtime.is_file():
                    raw = runtime.read_bytes()
            except OSError:
                print('[cctv-aptv] disk-cache-read-unavailable; using memory', flush=True)
        if hashlib.sha256(raw).hexdigest() != RUNTIME_SHA:
            try:
                raw, _ = get(RUNTIME_URL, limit=4*1024*1024)
            except PermissionError:
                raise NativeError('official-runtime-download-permission-denied') from None
            if hashlib.sha256(raw).hexdigest() != RUNTIME_SHA:
                raise NativeError('official-runtime-version-changed')
            if runtime is not None:
                temporary = runtime.with_name('runtime-'+uuid.uuid4().hex+'.tmp')
                try:
                    runtime.parent.mkdir(parents=True, exist_ok=True)
                    temporary.write_bytes(raw)
                    temporary.replace(runtime)
                except OSError:
                    print('[cctv-aptv] disk-cache-write-unavailable; using memory', flush=True)
                finally:
                    try:
                        temporary.unlink(missing_ok=True)
                    except OSError:
                        pass
        _RUNTIME_MEMORY = raw
        return raw


class Engine:
    def __init__(self, args):
        self.context = None
        raw = load_runtime(getattr(args, 'cache_dir', None))
        # Use Emscripten's normal instantiateWasm host hook for synchronous
        # compilation, avoiding a browser event loop for async WASM completion.
        match = re.search(rb'wasmBinaryFile="data:application/octet-stream;base64,([A-Za-z0-9+/=]+)"', raw)
        if not match:
            raise NativeError('official-wasm-not-found')
        wasm = match.group(1)
        try:
            self.context = JSContext(getattr(args, 'jscore_library', APPLE_FRAMEWORK))
            self.context.execute(JSCORE_HOST.replace('/live/cctv2/m/index.shtml',
                '/live/'+getattr(args, 'channel_id', 'cctv2')+'/m/index.shtml'))
            self.context.execute(IDB_SOURCE)
            self.context.execute(raw.decode('utf-8'))
            self._install_wasm(wasm)
            self.context.execute(JSCORE_BOOT)
            deadline = time.monotonic()+25
            while time.monotonic() < deadline:
                state = self.pump()
                if state.get('error'):
                    raise NativeError('official-runtime-initialization-failed')
                if state.get('init') and state.get('config') and state.get('pending') == 0:
                    self.context.execute(JSCORE_TRANSFORM)
                    print('[cctv-native] media-transfer='+('typed-array' if self.context.buffer_api else 'base64')+
                          ' channel='+getattr(args,'channel_id','cctv2'),flush=True)
                    return
                time.sleep(0.01)
            raise NativeError('official-runtime-initialization-timeout')
        except BaseException:
            self.close()
            raise

    def _install_wasm(self, encoded):
        if self.context.buffer_api:
            # The pinned SDK's public embedded binary is decoded unchanged by
            # Python's C implementation, then copied into a host-owned array.
            # __wasm roots it after the transient media input is released.
            self.context.put_media(base64.b64decode(encoded, validate=True))
            self.context.execute('var __wasm=__mediaInput;__mediaInput=null;')
        else:
            self.context.execute('var __wasmText=atob('+json.dumps(encoded.decode('ascii'))+');'
                'var __wasm=new Uint8Array(__wasmText.length);'
                'for(var i=0;i<__wasmText.length;i++)__wasm[i]=__wasmText.charCodeAt(i);'
                '__wasmText=null;')

    def pump(self):
        ctx = self.context
        ctx.execute('__tick()')
        requests = json.loads(ctx.evaluate('JSON.stringify(__requests.splice(0))'))
        if len(requests) > 32:
            raise NativeError('runtime-too-many-requests')
        for request in requests:
            # All SDK requests retain the ordinary proxy, certificate validation,
            # host restrictions and redirect validation used for media requests.
            target = urljoin(REFERER, request['url'])
            validate_source(target)
            if request['method'] != 'GET' or request.get('body'):
                raise NativeError('runtime-unsupported-http-request')
            try:
                raw, _ = get(target, headers=request.get('headers'), limit=4*1024*1024, timeout=8)
            except Exception:
                raise NativeError('official-runtime-network-failed') from None
            ctx.execute('__respond('+str(int(request['id']))+',200,'+
                         json.dumps(base64.b64encode(raw).decode())+')')
        # Drain several turns so IndexedDB transaction completion follows XHR.
        for _ in range(4):
            ctx.execute('__tick()')
        return json.loads(ctx.evaluate('JSON.stringify(Object.assign({},__state,'
                                      '{pending:Object.keys(__xhr).length+__requests.length}))'))

    def transform(self, units):
        if len(units) > 16384 or any(not x or len(x)>4*1024*1024 for x in units):
            raise NativeError('engine-invalid-media-input')
        if sum(map(len, units)) > 16*1024*1024:
            raise NativeError('engine-message-too-large')
        if not units:
            return []
        self.pump()
        if self.context.buffer_api:
            lengths = list(map(len,units))
            self.context.put_media(b''.join(units))
            sizes = json.loads(self.context.evaluate('__transformBinary('+json.dumps(lengths)+')'))
            if (not isinstance(sizes,list) or len(sizes)!=len(units)
                    or any(type(size) is not int or not 0 < size <= length for size,length in zip(sizes,lengths))):
                raise NativeError('engine-response-lengths-invalid')
            raw = self.context.read_media(sum(lengths))
            if sum(sizes) != len(raw):
                raise NativeError('engine-response-lengths-invalid')
            output,offset = [],0
            for size in sizes:
                output.append(raw[offset:offset+size]);offset+=size
            self.context.execute('__mediaOutput=null;__mediaInput=null;')
            if any(value[0]!=original[0] for original,value in zip(units,output)):
                raise NativeError('engine-response-invalid')
            return output
        encoded = json.dumps([base64.b64encode(x).decode() for x in units])
        values = json.loads(self.context.evaluate('__transform('+encoded+')', timeout=15))
        if not isinstance(values, list) or len(values) != len(units):
            raise NativeError('engine-response-count')
        output = [base64.b64decode(x, validate=True) for x in values]
        if any(not b or len(b)>len(a) or b[0]!=a[0] for a,b in zip(units,output)):
            raise NativeError('engine-response-invalid')
        return output

    def close(self):
        if self.context:
            self.context.close()
