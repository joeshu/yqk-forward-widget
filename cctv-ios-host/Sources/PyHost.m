#import "PyHost.h"
#import "JSPluginRuntime.h"
#import "NodePluginRuntime.h"
#import <pthread.h>
#import <limits.h>

#if __has_include(<Python.h>)
#import <Python.h>
#define PYHOST_AVAILABLE 1
#else
#define PYHOST_AVAILABLE 0
#endif

static pthread_mutex_t gLock = PTHREAD_MUTEX_INITIALIZER;
static BOOL gRunning = NO;
static BOOL gStartedOnce = NO;
static BOOL gThreadExited = NO;
static BOOL gInterpreterReady = NO;
static NSInteger gPort = 0;
static NSError *gStartupError;
static pthread_t gThread;
static NSString *gScriptPath;
static NSString *gDataDir;
static NSString *gPythonHome;
static NSArray<NSString *> *gArguments;
static void (^gLogHandler)(NSString *) = nil;
#if PYHOST_AVAILABLE
static PyObject *gServiceRuntime = NULL;
static PyObject *gWriteFunction = NULL;
static PyObject *gJSFunction = NULL;
static PyObject *gNodeFunction = NULL;
#endif

@implementation PyHost

+ (BOOL)running { pthread_mutex_lock(&gLock); BOOL v = gRunning; pthread_mutex_unlock(&gLock); return v || NodePluginRuntime.shared.hasActivePlugin; }
+ (BOOL)startedOnce { pthread_mutex_lock(&gLock); BOOL v = gStartedOnce; pthread_mutex_unlock(&gLock); return v; }
+ (NSInteger)port { pthread_mutex_lock(&gLock); NSInteger v = gPort; pthread_mutex_unlock(&gLock); return v; }
+ (NSError *)startupError {pthread_mutex_lock(&gLock);NSError *value=gStartupError;pthread_mutex_unlock(&gLock);return value;}
+ (void)setLogHandler:(void (^)(NSString *))handler {
    pthread_mutex_lock(&gLock); gLogHandler = [handler copy]; pthread_mutex_unlock(&gLock);
}

static void emitLog(NSString *text) {
    if (!text.length) return;
    NSArray<NSString *> *lines = [text componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet];
    pthread_mutex_lock(&gLock); void (^handler)(NSString *) = [gLogHandler copy]; pthread_mutex_unlock(&gLock);
    if (handler) for (NSString *line in lines) if (line.length) handler(line);
}
#if PYHOST_AVAILABLE
static PyObject *pyHostWrite(PyObject *self, PyObject *args) {
    @autoreleasepool { // Python callbacks may arrive on long-lived threads without a pool.
    const char *s = NULL; Py_ssize_t n = 0;
    if (!PyArg_ParseTuple(args, "y#", &s, &n)) return NULL;
    NSString *text = [[NSString alloc] initWithBytes:s length:(NSUInteger)n encoding:NSUTF8StringEncoding];
    if (text) emitLog(text);
    return PyLong_FromSsize_t(n);
    }
}
static PyObject *pyHostJSCall(PyObject *self, PyObject *args) {
    const char *operation=NULL,*json=NULL;
    if(!PyArg_ParseTuple(args,"ss",&operation,&json))return NULL;
    @autoreleasepool {
        NSString *op=[NSString stringWithUTF8String:operation];NSString *payload=[NSString stringWithUTF8String:json];
        NSString *reply=nil;NSError *error=nil;
        Py_BEGIN_ALLOW_THREADS
        reply=[[JSPluginRuntime shared] callOperation:op json:payload timeout:40 error:&error];
        Py_END_ALLOW_THREADS
        if(!reply){PyErr_SetString(PyExc_RuntimeError,error.localizedDescription.UTF8String?:"JS bridge failed");return NULL;}
        return PyUnicode_FromString(reply.UTF8String);
    }
}
static PyMethodDef jsMethod = {"_cctvhost_js_call", pyHostJSCall, METH_VARARGS, "Call the native JavaScriptCore plugin host."};
static PyObject *pyHostNodeCall(PyObject *self,PyObject *args){
    const char *operation=NULL,*json=NULL;if(!PyArg_ParseTuple(args,"ss",&operation,&json))return NULL;
    @autoreleasepool {
        NSString *op=[NSString stringWithUTF8String:operation],*payload=[NSString stringWithUTF8String:json];NSString *reply=nil;NSError *error=nil;
        Py_BEGIN_ALLOW_THREADS
        reply=[NodePluginRuntime.shared callOperation:op json:payload error:&error];
        Py_END_ALLOW_THREADS
        if(!reply){PyErr_SetString(PyExc_RuntimeError,error.localizedDescription.UTF8String?:"Node bridge failed");return NULL;}return PyUnicode_FromString(reply.UTF8String);
    }
}
static PyMethodDef nodeMethod={"_cctvhost_node_call",pyHostNodeCall,METH_VARARGS,"Call the local Node.js Mobile host."};
static PyMethodDef writeMethod = {"_pyhost_write", pyHostWrite, METH_VARARGS, "Forward Python output to the host log."};

static void *pyThread(void *unused) {
    @autoreleasepool {
        pthread_mutex_lock(&gLock); BOOL reused = gInterpreterReady; pthread_mutex_unlock(&gLock);
        PyGILState_STATE gil = PyGILState_UNLOCKED;
        if (reused) gil = PyGILState_Ensure();
        else {
        setenv("YSP_DATA_DIR", gDataDir.UTF8String, 1);
        NSString *caFile = [gPythonHome stringByAppendingPathComponent:@"ssl/cert.pem"];
        setenv("SSL_CERT_FILE", caFile.UTF8String, 1);
        setenv("SSL_CERT_DIR", "", 1);
        PyConfig config; PyConfig_InitPythonConfig(&config);
        config.install_signal_handlers = 0;
        PyStatus status = PyConfig_SetBytesString(&config, &config.home, gPythonHome.UTF8String);
        NSString *lib = [gPythonHome stringByAppendingPathComponent:@"lib/python3.13"];
        NSString *dyn = [lib stringByAppendingPathComponent:@"lib-dynload"];
        if (!PyStatus_Exception(status)) {
            config.module_search_paths_set = 1;
            wchar_t *wLib = Py_DecodeLocale(lib.fileSystemRepresentation, NULL);
            if (!wLib) status = PyStatus_NoMemory();
            else { status = PyWideStringList_Append(&config.module_search_paths, wLib); PyMem_RawFree(wLib); }
        }
        if (!PyStatus_Exception(status)) {
            wchar_t *wDyn = Py_DecodeLocale(dyn.fileSystemRepresentation, NULL);
            if (!wDyn) status = PyStatus_NoMemory();
            else { status = PyWideStringList_Append(&config.module_search_paths, wDyn); PyMem_RawFree(wDyn); }
        }
        if (!PyStatus_Exception(status)) status = Py_InitializeFromConfig(&config);
        PyConfig_Clear(&config);
        if (PyStatus_Exception(status)) {
            pthread_mutex_lock(&gLock);gStartupError=[NSError errorWithDomain:@"PyHost" code:11 userInfo:@{NSLocalizedDescriptionKey:@"Python 初始化失败，请查看日志并重开 App。"}];pthread_mutex_unlock(&gLock);
            emitLog([NSString stringWithFormat:@"Python 初始化失败: %s", status.err_msg ?: "unknown"]);
            goto finished;
        }
        pthread_mutex_lock(&gLock); gInterpreterReady = YES; pthread_mutex_unlock(&gLock);
        PyObject *sysPath = PySys_GetObject("path");
        NSString *vendor=[gPythonHome stringByAppendingPathComponent:@"lib/python3.13/site-packages"];
        if([NSFileManager.defaultManager fileExistsAtPath:vendor]){PyObject *site=PyUnicode_FromString(vendor.UTF8String);if(site && sysPath)PyList_Insert(sysPath,0,site);Py_XDECREF(site);}
        // Per-service import paths are installed and restored by the session manager.
        PyObject *builtins = PyEval_GetBuiltins();
        gWriteFunction = PyCFunction_New(&writeMethod, NULL);
        PyDict_SetItemString(builtins, "_pyhost_write", gWriteFunction);
        gJSFunction=PyCFunction_New(&jsMethod,NULL);
        PyDict_SetItemString(builtins,"_cctvhost_js_call",gJSFunction);
        gNodeFunction=PyCFunction_New(&nodeMethod,NULL);PyDict_SetItemString(builtins,"_cctvhost_node_call",gNodeFunction);
        [JSPluginRuntime shared].logHandler=^(NSString *line){emitLog([@"[JS] " stringByAppendingString:line]);};
        NodePluginRuntime.shared.logHandler=^(NSString *line){emitLog([@"[Node] " stringByAppendingString:line]);};
        PyObject *mainDict = PyDict_New();
        PyDict_SetItemString(mainDict, "__builtins__", builtins);
        PyObject *bootstrap = PyRun_String(
            "import sys, io\n"
            "class _HostStream(io.TextIOBase):\n"
            " def write(self, value):\n"
            "  _pyhost_write(value.encode('utf-8', 'replace'))\n"
            "  return len(value)\n"
            " def flush(self): pass\n"
            " def writable(self): return True\n"
            "sys.stdout = sys.stderr = _HostStream()\n", Py_file_input, mainDict, mainDict);
        Py_XDECREF(bootstrap); Py_XDECREF(mainDict);
        PyObject *resourceDir = PyUnicode_FromString(NSBundle.mainBundle.resourcePath.UTF8String);
        if (sysPath && resourceDir) PyList_Insert(sysPath, 0, resourceDir);
        Py_XDECREF(resourceDir);
        gServiceRuntime = PyImport_ImportModule("host_service_runtime");
        }
        PyObject *sys = PyImport_ImportModule("sys");
        NSString *portString = [NSString stringWithFormat:@"%ld", (long)gPort];
        setenv("YSP_LINKS_PER_DEVICE", "2", 1);
        setenv("YSP_ZAP_DEBOUNCE", "15", 1);
        emitLog(@"iOS 插件安全模式：TS 缓存 32MB / 高码率并发 2 / 换台防抖 15 秒");
        PyObject *argv = Py_BuildValue("[ssssssssssssss]", gScriptPath.UTF8String, portString.UTF8String, "--bind", "127.0.0.1", "--no-engine", "--data-dir", gDataDir.UTF8String, "--cache-mb", "32", "--links-per-device", "2", "--zap-debounce", "15", "--stable-playback");
        if (gArguments) {
            Py_XDECREF(argv);
            argv = PyList_New(gArguments.count + 1);
            PyList_SetItem(argv, 0, PyUnicode_FromString(gScriptPath.UTF8String));
            for (NSUInteger i=0;i<gArguments.count;i++) PyList_SetItem(argv,i+1,PyUnicode_FromString(gArguments[i].UTF8String));
        }
        if (sys && argv) PyObject_SetAttrString(sys, "argv", argv);
        Py_XDECREF(sys); Py_XDECREF(argv);
        if (gServiceRuntime) {
            PyObject *configured = PyObject_CallMethod(gServiceRuntime, "configure_environment", "si", gDataDir.UTF8String, (int)gPort);
            Py_XDECREF(configured);
        }
        PyObject *ns = gServiceRuntime ? PyObject_CallMethod(gServiceRuntime, "run_script", "s", gScriptPath.UTF8String) : NULL;
        if (ns) { Py_DECREF(ns); emitLog(@"Python 服务主脚本已返回，后台任务由宿主管理"); }
        else {
            // PyErr_Print handles SystemExit by terminating the embedding process.
            // Display the exception without allowing a plugin error to exit the App.
            PyObject *raised = PyErr_GetRaisedException();
            if (raised) {
                PyObject *text=PyObject_Str(raised);const char *utf8=text?PyUnicode_AsUTF8(text):NULL;NSString *message=utf8?[NSString stringWithUTF8String:utf8]:@"插件启动失败";if(message.length>1024)message=[message substringToIndex:1024];
                pthread_mutex_lock(&gLock);gStartupError=[NSError errorWithDomain:@"PyHost" code:12 userInfo:@{NSLocalizedDescriptionKey:message}];pthread_mutex_unlock(&gLock);
                Py_XDECREF(text);PyErr_DisplayException(raised);Py_DECREF(raised);
            }
            emitLog(@"Python 插件异常退出（详见上方日志）");
        }
        PyObject *idle = gServiceRuntime ? PyObject_CallMethod(gServiceRuntime, "is_idle", NULL) : NULL;
        BOOL clean = idle && PyObject_IsTrue(idle) > 0;
        Py_XDECREF(idle); PyErr_Clear();
        // Publish exit while holding the GIL: a replacement cannot enter Python
        // until this thread has finished every Python operation and released it.
        pthread_mutex_lock(&gLock); gRunning = !clean; gThreadExited = YES; pthread_mutex_unlock(&gLock);
        if (reused) PyGILState_Release(gil);
        else PyEval_SaveThread(); // Retain one interpreter; never finalize live extension modules.
        return NULL;
    }
finished:
    pthread_mutex_lock(&gLock); gRunning = NO; gThreadExited = YES; pthread_mutex_unlock(&gLock);
    return NULL;
}
#endif

+ (BOOL)startWithScript:(NSString *)scriptName port:(NSInteger)port dataDir:(NSString *)dataDir error:(NSError **)error {
    return [self startScriptAtPath:[NSBundle.mainBundle.resourcePath stringByAppendingPathComponent:scriptName] port:port dataDir:dataDir arguments:nil error:error];
}

+ (BOOL)startScriptAtPath:(NSString *)path port:(NSInteger)port dataDir:(NSString *)dataDir arguments:(NSArray<NSString *> *)arguments error:(NSError **)error {
    if(NodePluginRuntime.shared.hasActivePlugin){if(error)*error=[NSError errorWithDomain:@"PyHost" code:10 userInfo:@{NSLocalizedDescriptionKey:@"旧 Node 插件尚未停止，请先停止该资源再切换。"}];return NO;}
    pthread_mutex_lock(&gLock);
    if (gRunning || (gStartedOnce && !gThreadExited)) {
        pthread_mutex_unlock(&gLock);
        if (error) *error = [NSError errorWithDomain:@"PyHost" code:4 userInfo:@{NSLocalizedDescriptionKey:@"旧服务仍在运行或停止中，请等待它释放线程和端口后再启动。"}];
        return NO;
    }
    if (gStartedOnce && !gInterpreterReady) {
        pthread_mutex_unlock(&gLock);
        if (error) *error = [NSError errorWithDomain:@"PyHost" code:8 userInfo:@{NSLocalizedDescriptionKey:@"Python 初始化失败，请重开 App。"}];
        return NO;
    }
    NSString *res = NSBundle.mainBundle.resourcePath;
    NSString *script = path;
    NSString *home = [res stringByAppendingPathComponent:@"python"];
#if !PYHOST_AVAILABLE
    pthread_mutex_unlock(&gLock);
    if (error) *error = [NSError errorWithDomain:@"PyHost" code:3 userInfo:@{NSLocalizedDescriptionKey:@"此构建未包含 CPython 运行时；插件未启动。"}];
    return NO;
#else
    NSString *stdlib = [home stringByAppendingPathComponent:@"lib/python3.13"];
    NSString *dynload = [stdlib stringByAppendingPathComponent:@"lib-dynload"];
    NSString *caFile = [home stringByAppendingPathComponent:@"ssl/cert.pem"];
    BOOL runtimeOK = [[NSFileManager defaultManager] fileExistsAtPath:script] &&
        [[NSFileManager defaultManager] fileExistsAtPath:stdlib] &&
        [[NSFileManager defaultManager] fileExistsAtPath:dynload] &&
        [[NSFileManager defaultManager] fileExistsAtPath:caFile] &&
        [[NSFileManager defaultManager] fileExistsAtPath:[res stringByAppendingPathComponent:@"host_service_runtime.py"]];
    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray<NSString *> *extensionFiles = [fm contentsOfDirectoryAtPath:dynload error:nil] ?: @[];
    for (NSString *module in @[@"_ssl", @"_socket", @"_hashlib", @"select", @"_struct"]) {
        NSString *prefix = [module stringByAppendingString:@"."];
        BOOL found = NO;
        for (NSString *filename in extensionFiles) {
            if ([filename hasPrefix:prefix] && ([filename hasSuffix:@".fwork"] || [filename hasSuffix:@".so"])) { found = YES; break; }
        }
        if (!found) runtimeOK = NO;
    }
    if (!runtimeOK) {
        pthread_mutex_unlock(&gLock);
        if (error) *error = [NSError errorWithDomain:@"PyHost" code:1 userInfo:@{NSLocalizedDescriptionKey:@"Python 运行时不完整：需要插件、python/lib/python3.13/lib-dynload 中的 _ssl/_socket/_hashlib/select/_struct 设备扩展，以及 python/ssl/cert.pem。"}];
        return NO;
    }
    NSError *dirError = nil;
    if (![[NSFileManager defaultManager] createDirectoryAtPath:dataDir withIntermediateDirectories:YES attributes:nil error:&dirError]) {
        pthread_mutex_unlock(&gLock); if (error) *error = dirError; return NO;
    }
    gScriptPath = script; gPythonHome = home; gDataDir = dataDir; gPort = port; gArguments=[arguments copy];
    setenv("YSP_DATA_DIR", dataDir.UTF8String, 1);
    gStartedOnce = YES; gRunning = YES; gThreadExited = NO; gStartupError=nil;
    int rc = pthread_create(&gThread, NULL, pyThread, NULL);
    if (rc != 0) { gRunning = NO; gThreadExited = YES; gStartedOnce = gInterpreterReady; pthread_mutex_unlock(&gLock); if (error) *error = [NSError errorWithDomain:@"PyHost" code:5 userInfo:@{NSLocalizedDescriptionKey:[NSString stringWithFormat:@"无法创建 Python 线程 (%d)", rc]}]; return NO; }
    pthread_detach(gThread); pthread_mutex_unlock(&gLock); return YES;
#endif
}

+ (BOOL)stopWithError:(NSError **)error {
    if(NodePluginRuntime.shared.hasActivePlugin && ![NodePluginRuntime.shared stopWithError:error])return NO;
#if !PYHOST_AVAILABLE
    if (error) *error = [NSError errorWithDomain:@"PyHost" code:3 userInfo:@{NSLocalizedDescriptionKey:@"当前构建未包含 CPython。"}];
    return NO;
#else
    pthread_mutex_lock(&gLock);
    if (!gRunning) { BOOL exited = gThreadExited || !gStartedOnce; pthread_mutex_unlock(&gLock); return exited; }
    if (!gInterpreterReady) {
        pthread_mutex_unlock(&gLock);
        if (error) *error = [NSError errorWithDomain:@"PyHost" code:7 userInfo:@{NSLocalizedDescriptionKey:@"Python 正在初始化，请稍后停止服务。"}];
        return NO;
    }
    pthread_mutex_unlock(&gLock);
    PyGILState_STATE gil = PyGILState_Ensure();
    PyObject *result = gServiceRuntime ? PyObject_CallMethod(gServiceRuntime, "stop_session", "d", 5.0) : NULL;
    BOOL stopped = result && PyObject_IsTrue(result) > 0;
    Py_XDECREF(result);
    NSString *message = @"服务管理器尚未就绪，请稍后再试。";
    if (!stopped && gServiceRuntime) {
        PyObject *detail = PyObject_CallMethod(gServiceRuntime, "last_error", NULL);
        const char *text = detail && PyUnicode_Check(detail) ? PyUnicode_AsUTF8(detail) : NULL;
        if (text && *text) message = [NSString stringWithUTF8String:text];
        Py_XDECREF(detail);
    }
    PyErr_Clear(); PyGILState_Release(gil);
    if (!stopped) {
        if (error) *error = [NSError errorWithDomain:@"PyHost" code:6 userInfo:@{NSLocalizedDescriptionKey:message}];
        return NO;
    }
    // run_script has completed, but wait for the tiny native epilogue too.
    for (NSUInteger attempt=0; attempt<100; attempt++) {
        pthread_mutex_lock(&gLock); BOOL exited=gThreadExited; if(exited)gRunning=NO; pthread_mutex_unlock(&gLock);
        if(exited)return YES;
        [NSThread sleepForTimeInterval:0.01];
    }
    if (error) *error = [NSError errorWithDomain:@"PyHost" code:9 userInfo:@{NSLocalizedDescriptionKey:@"服务线程正在结束，请稍后重试。"}];
    return NO;
#endif
}
+ (void)stop { NSError *error = nil; if (![self stopWithError:&error] && error) emitLog(error.localizedDescription); }
@end
