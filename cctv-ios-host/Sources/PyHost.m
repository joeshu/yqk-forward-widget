#import "PyHost.h"
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
static NSInteger gPort = 0;
static pthread_t gThread;
static NSString *gScriptPath;
static NSString *gDataDir;
static NSString *gPythonHome;
static NSArray<NSString *> *gArguments;
static void (^gLogHandler)(NSString *) = nil;
#if PYHOST_AVAILABLE
static PyObject *gPluginNamespace = NULL;
static PyObject *gWriteFunction = NULL;
#endif

@implementation PyHost

+ (BOOL)running { pthread_mutex_lock(&gLock); BOOL v = gRunning; pthread_mutex_unlock(&gLock); return v; }
+ (BOOL)startedOnce { pthread_mutex_lock(&gLock); BOOL v = gStartedOnce; pthread_mutex_unlock(&gLock); return v; }
+ (NSInteger)port { pthread_mutex_lock(&gLock); NSInteger v = gPort; pthread_mutex_unlock(&gLock); return v; }
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
    const char *s = NULL; Py_ssize_t n = 0;
    if (!PyArg_ParseTuple(args, "y#", &s, &n)) return NULL;
    NSString *text = [[NSString alloc] initWithBytes:s length:(NSUInteger)n encoding:NSUTF8StringEncoding];
    if (text) emitLog(text);
    return PyLong_FromSsize_t(n);
}
static PyMethodDef writeMethod = {"_pyhost_write", pyHostWrite, METH_VARARGS, "Forward Python output to the host log."};

static void *pyThread(void *unused) {
    @autoreleasepool {
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
            emitLog([NSString stringWithFormat:@"Python 初始化失败: %s", status.err_msg ?: "unknown"]);
            goto finished;
        }
        PyObject *sysPath = PySys_GetObject("path");
        PyObject *scriptDir = PyUnicode_FromString(gScriptPath.stringByDeletingLastPathComponent.UTF8String);
        if (sysPath && scriptDir) PyList_Insert(sysPath, 0, scriptDir);
        Py_XDECREF(scriptDir);
        PyObject *builtins = PyEval_GetBuiltins();
        gWriteFunction = PyCFunction_New(&writeMethod, NULL);
        PyDict_SetItemString(builtins, "_pyhost_write", gWriteFunction);
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
        Py_XDECREF(bootstrap);
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
        PyObject *runpy = PyImport_ImportModule("runpy");
        PyObject *runPath = runpy ? PyObject_GetAttrString(runpy, "run_path") : NULL;
        PyObject *path = PyUnicode_FromString(gScriptPath.UTF8String);
        PyObject *kw = Py_BuildValue("{s:s}", "run_name", "__main__");
        PyObject *ns = (runPath && path && kw) ? PyObject_Call(runPath, PyTuple_Pack(1, path), kw) : NULL;
        Py_XDECREF(runpy); Py_XDECREF(runPath); Py_XDECREF(path); Py_XDECREF(kw);
        if (ns) { gPluginNamespace = ns; emitLog(@"Python 插件服务已退出"); }
        else { PyErr_Print(); emitLog(@"Python 插件异常退出（详见上方日志）"); }
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
    pthread_mutex_lock(&gLock);
    if (gRunning) { pthread_mutex_unlock(&gLock); return YES; }
    if (gStartedOnce) {
        pthread_mutex_unlock(&gLock);
        if (error) *error = [NSError errorWithDomain:@"PyHost" code:4 userInfo:@{NSLocalizedDescriptionKey:@"CPython 进程内不可安全重启；本次启动已使用或停止，请重启 App。"}];
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
        [[NSFileManager defaultManager] fileExistsAtPath:caFile];
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
    gStartedOnce = YES; gRunning = YES; gThreadExited = NO;
    int rc = pthread_create(&gThread, NULL, pyThread, NULL);
    if (rc != 0) { gRunning = NO; pthread_mutex_unlock(&gLock); if (error) *error = [NSError errorWithDomain:@"PyHost" code:5 userInfo:@{NSLocalizedDescriptionKey:[NSString stringWithFormat:@"无法创建 Python 线程 (%d)", rc]}]; return NO; }
    pthread_detach(gThread); pthread_mutex_unlock(&gLock); return YES;
#endif
}

+ (BOOL)stopWithError:(NSError **)error {
#if !PYHOST_AVAILABLE
    if (error) *error = [NSError errorWithDomain:@"PyHost" code:3 userInfo:@{NSLocalizedDescriptionKey:@"当前构建未包含 CPython。"}];
    return NO;
#else
    pthread_mutex_lock(&gLock);
    if (!gRunning) { BOOL exited = gThreadExited || !gStartedOnce; pthread_mutex_unlock(&gLock); return exited; }
    pthread_mutex_unlock(&gLock);
    PyGILState_STATE gil = PyGILState_Ensure();
    PyObject *stop = PyDict_GetItemString(PyEval_GetBuiltins(), "_cctvhost_stop_service");
    if (!stop) stop = PyDict_GetItemString(PyEval_GetBuiltins(), "_ysp_stop_server");
    PyObject *result = stop ? PyObject_CallNoArgs(stop) : NULL;
    int truth = result ? PyObject_IsTrue(result) : 0;
    BOOL stopped = truth > 0;
    if (!result || truth < 0) PyErr_Clear();
    Py_XDECREF(result); PyGILState_Release(gil);
    if (!stopped) {
        if (error) *error = [NSError errorWithDomain:@"PyHost" code:6 userInfo:@{NSLocalizedDescriptionKey:@"插件停止回调缺失或停止失败；未伪报停止，Python 线程仍可能运行。"}];
        return NO;
    }
    return YES;
#endif
}
+ (void)stop { NSError *error = nil; if (![self stopWithError:&error] && error) emitLog(error.localizedDescription); }
@end
