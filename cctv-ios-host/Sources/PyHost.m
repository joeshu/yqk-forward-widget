#import "PyHost.h"
#import "JSPluginRuntime.h"
#import "NodePluginRuntime.h"
#import "RuntimeDiagnostics.h"
#import <pthread.h>
#import <stdlib.h>
#import <time.h>
#import <QuartzCore/QuartzCore.h>

#if __has_include(<Python.h>)
#define PY_SSIZE_T_CLEAN
#import <Python.h>
#define PYHOST_AVAILABLE 1
#else
#define PYHOST_AVAILABLE 0
#endif

@interface PyHostTask : NSObject
@property(nonatomic, copy) NSString *identifier;
@property(nonatomic, copy) NSString *scriptPath;
@property(nonatomic, copy) NSString *dataDir;
@property(nonatomic, copy) NSString *pythonHome;
@property(nonatomic, copy) NSArray<NSString *> *arguments;
@property(nonatomic, copy) void (^logHandler)(NSString *);
@property(nonatomic) NSInteger port;
@property(nonatomic) pthread_t thread;
@property(nonatomic) BOOL initializesInterpreter;
@property(nonatomic) BOOL running;
@property(nonatomic) BOOL stopping;
@property(nonatomic) BOOL threadExited;
@property(nonatomic) BOOL sessionReady;
@property(nonatomic, strong) NSError *error;
@end
@implementation PyHostTask @end

static pthread_mutex_t gLock = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t gCondition = PTHREAD_COND_INITIALIZER;
static NSMutableDictionary<NSString *, PyHostTask *> *gTasks;
static NSMutableDictionary<NSString *, NSError *> *gTaskFailures;
static NSMutableDictionary<NSString *, void (^)(NSString *)> *gLogHandlers;
static void (^gFallbackLogHandler)(NSString *);
static BOOL gStartedOnce = NO;
static BOOL gInterpreterReady = NO;
static BOOL gInterpreterInitializing = NO;
static NSError *gInterpreterFailure;
#if PYHOST_AVAILABLE
static PyObject *gServiceRuntime = NULL;
static PyObject *gWriteFunction = NULL;
static PyObject *gJSFunction = NULL;
static PyObject *gNodeFunction = NULL;
#endif

NSNotificationName const PyHostRuntimeStateDidChangeNotification = @"PyHostRuntimeStateDidChangeNotification";

static void ensureMaps(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{ gTasks = [NSMutableDictionary dictionary]; gTaskFailures = [NSMutableDictionary dictionary]; gLogHandlers = [NSMutableDictionary dictionary]; });
}
static void notifyRuntimeStateChanged(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        [NSNotificationCenter.defaultCenter postNotificationName:PyHostRuntimeStateDidChangeNotification object:nil];
    });
}
static void emitLogForIdentifier(NSString *identifier, NSString *text) {
    if (!text.length) return;
    ensureMaps();
    NSArray<NSString *> *lines = [text componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet];
    pthread_mutex_lock(&gLock);
    void (^handler)(NSString *) = [((identifier.length ? gLogHandlers[identifier] : nil) ?: gFallbackLogHandler) copy];
    pthread_mutex_unlock(&gLock);
    if (handler) for (NSString *line in lines) if (line.length) handler(line);
}
static void emitLog(NSString *text) { emitLogForIdentifier(nil, text); }

@implementation PyHost

+ (BOOL)running {
    ensureMaps(); pthread_mutex_lock(&gLock);
    BOOL active = NO; for (PyHostTask *task in gTasks.allValues) if (task.running) { active = YES; break; }
    pthread_mutex_unlock(&gLock);
    return active || NodePluginRuntime.shared.hasActivePlugin || JSPluginRuntime.shared.activeSessionIdentifiers.count > 0;
}
+ (BOOL)isRunningServiceIdentifier:(NSString *)identifier {
    if (!identifier.length) return NO;
    ensureMaps(); pthread_mutex_lock(&gLock); BOOL active = gTasks[identifier].running; pthread_mutex_unlock(&gLock);
    return active || [NodePluginRuntime.shared isRunningServiceIdentifier:identifier] || [JSPluginRuntime.shared.activeSessionIdentifiers containsObject:identifier];
}
+ (BOOL)isManagedServiceIdentifier:(NSString *)identifier {
    if(!identifier.length)return NO;
    ensureMaps();pthread_mutex_lock(&gLock);PyHostTask *task=gTasks[identifier];BOOL pythonManaged=task&&(task.running||!task.threadExited);pthread_mutex_unlock(&gLock);
    return pythonManaged||[[NodePluginRuntime.shared managedServiceIdentifiers] containsObject:identifier]||[[JSPluginRuntime.shared managedServiceIdentifiers] containsObject:identifier];
}
+ (BOOL)isStartingServiceIdentifier:(NSString *)identifier {
    if(!identifier.length)return NO;
    ensureMaps();pthread_mutex_lock(&gLock);PyHostTask *task=gTasks[identifier];BOOL pythonStarting=task&&!task.threadExited&&!task.sessionReady&&!task.stopping;pthread_mutex_unlock(&gLock);
    return pythonStarting||[NodePluginRuntime.shared isStartingServiceIdentifier:identifier]||([[JSPluginRuntime.shared managedServiceIdentifiers] containsObject:identifier]&&![JSPluginRuntime.shared.activeSessionIdentifiers containsObject:identifier]);
}
+ (BOOL)hasUncertainSessionForServiceIdentifier:(NSString *)identifier {
    return identifier.length&&[NodePluginRuntime.shared hasUncertainSessionForServiceIdentifier:identifier];
}
+ (NSArray<NSString *> *)runningServiceIdentifiers {
    ensureMaps(); pthread_mutex_lock(&gLock); NSMutableArray *ids = [NSMutableArray array];
    for (PyHostTask *task in gTasks.allValues) if (task.running && task.identifier.length) [ids addObject:task.identifier];
    pthread_mutex_unlock(&gLock);
    for (NSString *identifier in NodePluginRuntime.shared.activeSessionIdentifiers) if (![ids containsObject:identifier]) [ids addObject:identifier];
    for (NSString *identifier in JSPluginRuntime.shared.activeSessionIdentifiers) if (![ids containsObject:identifier]) [ids addObject:identifier];
    return ids.copy;
}
+ (BOOL)startedOnce { pthread_mutex_lock(&gLock); BOOL value = gStartedOnce; pthread_mutex_unlock(&gLock); return value; }
+ (NSInteger)port {
    ensureMaps(); pthread_mutex_lock(&gLock); NSInteger value = 0;
    for (PyHostTask *task in gTasks.allValues) if (task.running) { value = task.port; break; }
    pthread_mutex_unlock(&gLock); return value;
}
+ (NSError *)startupError {
    pthread_mutex_lock(&gLock); NSError *value = gInterpreterFailure; pthread_mutex_unlock(&gLock); return value;
}
+ (NSError *)startupErrorForServiceIdentifier:(NSString *)identifier {ensureMaps();pthread_mutex_lock(&gLock);NSError *value=gTasks[identifier].error?:gTaskFailures[identifier]?:gInterpreterFailure;pthread_mutex_unlock(&gLock);return value;}
+ (NSString *)runtimeStatusDescription {
    NSArray *identifiers = self.runningServiceIdentifiers;
    pthread_mutex_lock(&gLock); BOOL initializing = gInterpreterInitializing; BOOL ready = gInterpreterReady; NSError *failure = gInterpreterFailure; pthread_mutex_unlock(&gLock);
    if (failure) return @"启动异常 · 查看日志";
    if (!identifiers.count) return initializing ? @"Python 初始化中" : @"已停止";
    if (initializing || !ready) return @"运行时初始化中";
    return [NSString stringWithFormat:@"%lu 个服务运行中 · HTTP 状态单独检测", (unsigned long)identifiers.count];
}
+ (NSString *)runtimeStatusDescriptionForServiceIdentifier:(NSString *)identifier {
    if (![identifier isKindOfClass:NSString.class] || !identifier.length) return @"服务 ID 未知";
    if ([NodePluginRuntime.shared isStartingServiceIdentifier:identifier]) return @"Node 服务启动中 · HTTP 健康状态未知";
    if ([self hasUncertainSessionForServiceIdentifier:identifier]) return @"Node 启动结果未知 · 可尝试停止后重试";
    if ([[JSPluginRuntime.shared managedServiceIdentifiers] containsObject:identifier] && ![JSPluginRuntime.shared.activeSessionIdentifiers containsObject:identifier]) return @"JavaScriptCore 会话启动中或待回收";
    ensureMaps();pthread_mutex_lock(&gLock);PyHostTask *task=gTasks[identifier];BOOL pythonStarting=task&&!task.threadExited&&!task.sessionReady&&!task.stopping;NSError *failure=task.error?:gTaskFailures[identifier];pthread_mutex_unlock(&gLock);
    if(pythonStarting)return @"Python 服务启动中 · HTTP 健康状态未知";
    if ([self isRunningServiceIdentifier:identifier]) return @"该服务的运行会话活跃 · HTTP 健康状态未知";
    if(!failure){pthread_mutex_lock(&gLock);failure=gInterpreterFailure;pthread_mutex_unlock(&gLock);}
    if (failure) return [NSString stringWithFormat:@"启动异常 · %@", failure.localizedDescription ?: @"查看服务日志"];
    return @"已停止 · HTTP 健康状态未知";
}
+ (void)setLogHandler:(void (^)(NSString *))handler {
    ensureMaps(); pthread_mutex_lock(&gLock); gFallbackLogHandler = [handler copy]; pthread_mutex_unlock(&gLock);
}
+ (void)setLogHandler:(void (^)(NSString *))handler forServiceIdentifier:(NSString *)identifier {
    if (!identifier.length) { [self setLogHandler:handler]; return; }
    ensureMaps(); pthread_mutex_lock(&gLock); if (handler) gLogHandlers[identifier] = [handler copy]; else [gLogHandlers removeObjectForKey:identifier]; pthread_mutex_unlock(&gLock);
}

#if PYHOST_AVAILABLE
static NSString *CCTVPluginBridgeServiceID(NSString *json) {
    NSData *data=[json dataUsingEncoding:NSUTF8StringEncoding];
    id payload=data?[NSJSONSerialization JSONObjectWithData:data options:0 error:NULL]:nil;
    if(![payload isKindOfClass:NSDictionary.class])return @"unknown";
    NSString *serviceID=[payload[@"serviceID"] isKindOfClass:NSString.class]?payload[@"serviceID"]:nil;
    if(!serviceID.length)serviceID=[payload[@"session"] isKindOfClass:NSString.class]?payload[@"session"]:nil;
    return serviceID.length?serviceID:@"unknown";
}
static void CCTVRecordPluginBridgeResult(NSString *engine, NSString *operation, NSString *serviceID, NSString *requestID, NSTimeInterval startedAt, NSString *reply, NSError *bridgeError) {
    if(!RuntimeDiagnostics.shared.enabled)return;
    id result=nil;
    if(reply.length)result=[NSJSONSerialization JSONObjectWithData:[reply dataUsingEncoding:NSUTF8StringEncoding] options:NSJSONReadingFragmentsAllowed error:NULL];
    BOOL resultIsDictionary=[result isKindOfClass:NSDictionary.class];
    BOOL operationOK=resultIsDictionary&&[result[@"ok"] isKindOfClass:NSNumber.class]&&[result[@"ok"] boolValue];
    NSString *failureStage=bridgeError?@"bridge_runtime_error":(!reply.length?@"empty_bridge_response":(!resultIsDictionary?@"invalid_bridge_response":(!operationOK?@"plugin_operation_error":@"none")));
    NSMutableDictionary *fields=[@{@"engine":engine?:@"unknown",
                                    @"operation":operation?:@"unknown",
                                    @"service_id":serviceID?:@"unknown",
                                    @"request_id":requestID?:@"",
                                    @"elapsed_ms":@((NSInteger)((CACurrentMediaTime()-startedAt)*1000)),
                                    @"response_bytes":@([reply lengthOfBytesUsingEncoding:NSUTF8StringEncoding]),
                                    @"failure_stage":failureStage,
                                    @"response_ok":@(operationOK),
                                    @"error_domain":bridgeError.domain?:@"",
                                    @"error_code":@(bridgeError.code)} mutableCopy];
    id pluginError=resultIsDictionary?result[@"error"]:nil;
    NSString *message=[pluginError isKindOfClass:NSString.class]?pluginError:([pluginError isKindOfClass:NSDictionary.class]&&[pluginError[@"message"] isKindOfClass:NSString.class]?pluginError[@"message"]:nil);
    if(!message.length)message=bridgeError.localizedDescription;
    if(message.length)fields[@"error_message"]=message;
    [RuntimeDiagnostics.shared recordEvent:operationOK?@"plugin_bridge_succeeded":@"plugin_bridge_failed" category:@"plugin" fields:fields];
}
static PyObject *pyHostWrite(PyObject *self, PyObject *args) {
    @autoreleasepool {
        const char *bytes = NULL, *session = NULL; Py_ssize_t length = 0;
        if (!PyArg_ParseTuple(args, "y#|s", &bytes, &length, &session)) return NULL;
        NSString *text = [[NSString alloc] initWithBytes:bytes length:(NSUInteger)length encoding:NSUTF8StringEncoding];
        if (text) emitLogForIdentifier(session ? [NSString stringWithUTF8String:session] : nil, text);
        return PyLong_FromSsize_t(length);
    }
}
static PyObject *pyHostJSCall(PyObject *self, PyObject *args) {
    const char *operation = NULL, *json = NULL;
    if (!PyArg_ParseTuple(args, "ss", &operation, &json)) return NULL;
    @autoreleasepool {
        BOOL diagnosticsEnabled=RuntimeDiagnostics.shared.enabled;
        NSString *operationName=[NSString stringWithUTF8String:operation];
        NSString *requestJSON=[NSString stringWithUTF8String:json];
        NSString *serviceID=diagnosticsEnabled?CCTVPluginBridgeServiceID(requestJSON):@"";
        NSString *requestID=diagnosticsEnabled?NSUUID.UUID.UUIDString.lowercaseString:@"";
        NSTimeInterval startedAt=diagnosticsEnabled?CACurrentMediaTime():0;
        if(diagnosticsEnabled)[RuntimeDiagnostics.shared recordEvent:@"plugin_bridge_started" category:@"plugin" fields:@{@"engine":@"javascriptcore", @"operation":operationName?:@"unknown", @"service_id":serviceID, @"request_id":requestID}];
        NSString *reply = nil; NSError *error = nil;
        Py_BEGIN_ALLOW_THREADS
        reply = [[JSPluginRuntime shared] callOperation:operationName json:requestJSON timeout:40 error:&error];
        Py_END_ALLOW_THREADS
        if(diagnosticsEnabled)CCTVRecordPluginBridgeResult(@"javascriptcore",operationName,serviceID,requestID,startedAt,reply,error);
        if (!reply) { PyErr_SetString(PyExc_RuntimeError, error.localizedDescription.UTF8String ?: "JS bridge failed"); return NULL; }
        return PyUnicode_FromString(reply.UTF8String);
    }
}
static PyObject *pyHostNodeCall(PyObject *self, PyObject *args) {
    const char *operation = NULL, *json = NULL;
    if (!PyArg_ParseTuple(args, "ss", &operation, &json)) return NULL;
    @autoreleasepool {
        BOOL diagnosticsEnabled=RuntimeDiagnostics.shared.enabled;
        NSString *operationName=[NSString stringWithUTF8String:operation];
        NSString *requestJSON=[NSString stringWithUTF8String:json];
        NSString *serviceID=diagnosticsEnabled?CCTVPluginBridgeServiceID(requestJSON):@"";
        NSString *requestID=diagnosticsEnabled?NSUUID.UUID.UUIDString.lowercaseString:@"";
        NSTimeInterval startedAt=diagnosticsEnabled?CACurrentMediaTime():0;
        if(diagnosticsEnabled)[RuntimeDiagnostics.shared recordEvent:@"plugin_bridge_started" category:@"plugin" fields:@{@"engine":@"node", @"operation":operationName?:@"unknown", @"service_id":serviceID, @"request_id":requestID}];
        NSString *reply = nil; NSError *error = nil;
        Py_BEGIN_ALLOW_THREADS
        reply = [NodePluginRuntime.shared callOperation:operationName json:requestJSON error:&error];
        Py_END_ALLOW_THREADS
        if(diagnosticsEnabled)CCTVRecordPluginBridgeResult(@"node",operationName,serviceID,requestID,startedAt,reply,error);
        if (!reply) { PyErr_SetString(PyExc_RuntimeError, error.localizedDescription.UTF8String ?: "Node bridge failed"); return NULL; }
        return PyUnicode_FromString(reply.UTF8String);
    }
}
static PyMethodDef writeMethod = {"_pyhost_write", pyHostWrite, METH_VARARGS, "Forward Python output to its service log."};
static PyMethodDef jsMethod = {"_cctvhost_js_call", pyHostJSCall, METH_VARARGS, "Call the native JavaScriptCore plugin host."};
static PyMethodDef nodeMethod = {"_cctvhost_node_call", pyHostNodeCall, METH_VARARGS, "Call the Node.js Mobile plugin host."};

static BOOL initializeInterpreter(PyHostTask *task, NSError **failure) {
    NSString *home = task.pythonHome;
    setenv("SSL_CERT_FILE", [[home stringByAppendingPathComponent:@"ssl/cert.pem"] UTF8String], 1);
    setenv("SSL_CERT_DIR", "", 1);
    PyConfig config; PyConfig_InitPythonConfig(&config); config.install_signal_handlers = 0;
    PyStatus status = PyConfig_SetBytesString(&config, &config.home, home.UTF8String);
    NSString *lib = [home stringByAppendingPathComponent:@"lib/python3.13"];
    NSString *dyn = [lib stringByAppendingPathComponent:@"lib-dynload"];
    if (!PyStatus_Exception(status)) {
        config.module_search_paths_set = 1;
        wchar_t *value = Py_DecodeLocale(lib.fileSystemRepresentation, NULL);
        if (!value) status = PyStatus_NoMemory(); else { status = PyWideStringList_Append(&config.module_search_paths, value); PyMem_RawFree(value); }
    }
    if (!PyStatus_Exception(status)) {
        wchar_t *value = Py_DecodeLocale(dyn.fileSystemRepresentation, NULL);
        if (!value) status = PyStatus_NoMemory(); else { status = PyWideStringList_Append(&config.module_search_paths, value); PyMem_RawFree(value); }
    }
    if (!PyStatus_Exception(status)) status = Py_InitializeFromConfig(&config);
    PyConfig_Clear(&config);
    if (PyStatus_Exception(status)) {
        NSString *message = [NSString stringWithFormat:@"Python 初始化失败: %s", status.err_msg ?: "unknown"];
        if (failure) *failure = [NSError errorWithDomain:@"PyHost" code:11 userInfo:@{NSLocalizedDescriptionKey:message}];
        return NO;
    }
    PyObject *sysPath = PySys_GetObject("path");
    NSString *vendor = [home stringByAppendingPathComponent:@"lib/python3.13/site-packages"];
    if ([NSFileManager.defaultManager fileExistsAtPath:vendor]) { PyObject *site = PyUnicode_FromString(vendor.UTF8String); if (site && sysPath) PyList_Insert(sysPath, 0, site); Py_XDECREF(site); }
    PyObject *builtins = PyEval_GetBuiltins();
    gWriteFunction = PyCFunction_New(&writeMethod, NULL); PyDict_SetItemString(builtins, "_pyhost_write", gWriteFunction);
    gJSFunction = PyCFunction_New(&jsMethod, NULL); PyDict_SetItemString(builtins, "_cctvhost_js_call", gJSFunction);
    gNodeFunction = PyCFunction_New(&nodeMethod, NULL); PyDict_SetItemString(builtins, "_cctvhost_node_call", gNodeFunction);
    [JSPluginRuntime shared].logHandler = ^(NSString *line) { emitLog([@"[JS] " stringByAppendingString:line]); };
    NodePluginRuntime.shared.logHandler = ^(NSString *line) { emitLog([@"[Node] " stringByAppendingString:line]); };
    PyObject *mainDict = PyDict_New(); PyDict_SetItemString(mainDict, "__builtins__", builtins);
    const char *bootstrapSource =
        "import sys, io, threading\n"
        "class _HostStream(io.TextIOBase):\n"
        " def write(self, value):\n"
        "  owner = getattr(threading.current_thread(), '_host_session', None)\n"
        "  raw = value.encode('utf-8', 'replace')\n"
        "  _pyhost_write(raw, owner.identifier) if owner else _pyhost_write(raw)\n"
        "  return len(value)\n"
        " def flush(self): pass\n"
        " def writable(self): return True\n"
        "sys.stdout = sys.stderr = _HostStream()\n";
    PyObject *bootstrap = PyRun_String(bootstrapSource, Py_file_input, mainDict, mainDict); Py_XDECREF(bootstrap); Py_XDECREF(mainDict);
    PyObject *resourceDir = PyUnicode_FromString(NSBundle.mainBundle.resourcePath.UTF8String);
    if (sysPath && resourceDir) PyList_Insert(sysPath, 0, resourceDir); Py_XDECREF(resourceDir);
    gServiceRuntime = PyImport_ImportModule("host_service_runtime");
    if (!gServiceRuntime) { PyErr_Clear(); if (failure) *failure = [NSError errorWithDomain:@"PyHost" code:12 userInfo:@{NSLocalizedDescriptionKey:@"Python 服务管理器加载失败"}]; return NO; }
    emitLog(@"Python 共享解释器就绪；服务脚本按 ID 分别跟踪，解释器内部并非进程级隔离");
    return YES;
}

static void taskFinished(PyHostTask *task, BOOL active, NSError *error) {
    ensureMaps();pthread_mutex_lock(&gLock); task.running = active; task.error = error; task.threadExited = YES;BOOL stopRequested=task.stopping;
    if(!active && gTasks[task.identifier]==task){[gTasks removeObjectForKey:task.identifier];if(error)gTaskFailures[task.identifier]=error;else [gTaskFailures removeObjectForKey:task.identifier];if(gTaskFailures.count>256)[gTaskFailures removeObjectForKey:gTaskFailures.allKeys.firstObject];}
    pthread_cond_broadcast(&gCondition); pthread_mutex_unlock(&gLock);
    NSString *event=error?@"python_runtime_failed":(active?@"python_runtime_background_work_active":(stopRequested?@"python_runtime_stopped":@"python_runtime_exited_unexpectedly"));
    NSMutableDictionary *fields=[@{@"engine":@"python", @"service_id":task.identifier?:@"unknown", @"port":@(task.port), @"background_work_active":@(active), @"stop_requested":@(stopRequested), @"unexpected_exit":@(!active&&!stopRequested&&!error), @"error_domain":error.domain?:@"", @"error_code":@(error.code)} mutableCopy];
    if(error.localizedDescription.length)fields[@"error_message"]=error.localizedDescription;
    if(error)fields[@"failure_stage"]=error.code==11?@"interpreter_initialization":(error.code==12?@"script_entry":@"runtime_task");
    [RuntimeDiagnostics.shared recordEvent:event category:@"plugin" fields:fields];
    notifyRuntimeStateChanged();
}

static void *pyThread(void *rawTask) {
    @autoreleasepool {
        PyHostTask *task = (__bridge_transfer PyHostTask *)rawTask;
        BOOL initialize = NO;
        pthread_mutex_lock(&gLock);
        if (task.initializesInterpreter) initialize = YES;
        else while (gInterpreterInitializing && !gInterpreterReady && !gInterpreterFailure) pthread_cond_wait(&gCondition, &gLock);
        BOOL ready = gInterpreterReady; NSError *initFailure = gInterpreterFailure;
        pthread_mutex_unlock(&gLock);
        PyGILState_STATE gil = PyGILState_UNLOCKED;
        if (initialize) {
            NSError *failure = nil;
            if (!initializeInterpreter(task, &failure)) {
                pthread_mutex_lock(&gLock); gInterpreterFailure = failure; gInterpreterInitializing = NO; pthread_cond_broadcast(&gCondition); pthread_mutex_unlock(&gLock);
                emitLogForIdentifier(task.identifier, failure.localizedDescription); taskFinished(task, NO, failure); if (Py_IsInitialized()) PyEval_SaveThread(); return NULL;
            }
            pthread_mutex_lock(&gLock); gInterpreterReady = YES; gInterpreterInitializing = NO; pthread_cond_broadcast(&gCondition); pthread_mutex_unlock(&gLock);
        } else if (ready) gil = PyGILState_Ensure();
        else {
            NSError *failure = initFailure ?: [NSError errorWithDomain:@"PyHost" code:8 userInfo:@{NSLocalizedDescriptionKey:@"Python 初始化失败，请重开 App。"}];
            taskFinished(task, NO, failure); return NULL;
        }

        pthread_mutex_lock(&gLock);BOOL cancelled=task.stopping;if(!cancelled){task.sessionReady=YES;task.running=YES;}pthread_cond_broadcast(&gCondition);pthread_mutex_unlock(&gLock);
        if(cancelled){if(initialize)PyEval_SaveThread();else PyGILState_Release(gil);taskFinished(task,NO,nil);return NULL;}
        [RuntimeDiagnostics.shared recordEvent:@"python_script_entry_started" category:@"plugin" fields:@{@"engine":@"python", @"service_id":task.identifier?:@"unknown", @"port":@(task.port)}];
        notifyRuntimeStateChanged();

        PyObject *path = PyUnicode_FromString(task.scriptPath.UTF8String);
        PyObject *identifier = PyUnicode_FromString(task.identifier.UTF8String);
        PyObject *dataDir = PyUnicode_FromString(task.dataDir.UTF8String);
        PyObject *port = PyLong_FromLong((long)task.port);
        PyObject *arguments = PyList_New((Py_ssize_t)task.arguments.count);
        for (NSUInteger index = 0; index < task.arguments.count; index++) PyList_SET_ITEM(arguments, (Py_ssize_t)index, PyUnicode_FromString(task.arguments[index].UTF8String));
        emitLogForIdentifier(task.identifier, @"Python 服务启动请求已交给运行时");
        PyObject *run = PyObject_GetAttrString(gServiceRuntime, "run_script");
        PyObject *result = (run && path && identifier && dataDir && port && arguments)
            ? PyObject_CallFunctionObjArgs(run, path, identifier, dataDir, port, arguments, NULL) : NULL;
        Py_XDECREF(run); Py_XDECREF(path); Py_XDECREF(identifier); Py_XDECREF(dataDir); Py_XDECREF(port); Py_XDECREF(arguments);
        NSError *failure = nil;
        if (result) { Py_DECREF(result); emitLogForIdentifier(task.identifier, @"Python 服务入口已返回；宿主继续跟踪该服务的后台任务"); }
        else {
            PyObject *raised = PyErr_GetRaisedException();
            if (raised) { PyObject *text = PyObject_Str(raised); const char *utf8 = text ? PyUnicode_AsUTF8(text) : NULL; NSString *message = utf8 ? [NSString stringWithUTF8String:utf8] : @"Python 插件启动失败"; if (message.length > 1024) message = [message substringToIndex:1024]; failure = [NSError errorWithDomain:@"PyHost" code:12 userInfo:@{NSLocalizedDescriptionKey:message}]; Py_XDECREF(text); PyErr_DisplayException(raised); Py_DECREF(raised); }
            emitLogForIdentifier(task.identifier, @"Python 插件异常退出（详见该服务日志）");
        }
        PyErr_Clear();
        PyObject *idleFunction = PyObject_GetAttrString(gServiceRuntime, "is_idle");
        PyObject *serviceID = PyUnicode_FromString(task.identifier.UTF8String);
        PyObject *idle = idleFunction && serviceID ? PyObject_CallFunctionObjArgs(idleFunction, serviceID, NULL) : NULL;
        BOOL clean = idle && PyObject_IsTrue(idle) > 0;
        Py_XDECREF(idleFunction); Py_XDECREF(serviceID); Py_XDECREF(idle); PyErr_Clear();
        taskFinished(task, !clean, failure);
        if (initialize) PyEval_SaveThread(); else PyGILState_Release(gil);
        return NULL;
    }
}
#endif

+ (BOOL)startWithScript:(NSString *)scriptName port:(NSInteger)port dataDir:(NSString *)dataDir error:(NSError **)error {
    return [self startScriptAtPath:[NSBundle.mainBundle.resourcePath stringByAppendingPathComponent:scriptName] identifier:scriptName port:port dataDir:dataDir arguments:nil error:error];
}
+ (BOOL)startScriptAtPath:(NSString *)path port:(NSInteger)port dataDir:(NSString *)dataDir arguments:(NSArray<NSString *> *)arguments error:(NSError **)error {
    return [self startScriptAtPath:path identifier:path.lastPathComponent port:port dataDir:dataDir arguments:arguments error:error];
}
+ (BOOL)startScriptAtPath:(NSString *)path identifier:(NSString *)identifier port:(NSInteger)port dataDir:(NSString *)dataDir arguments:(NSArray<NSString *> *)arguments error:(NSError **)error {
    ensureMaps();
    if (!identifier.length || !path.length || !dataDir.length) { if (error) *error = [NSError errorWithDomain:@"PyHost" code:2 userInfo:@{NSLocalizedDescriptionKey:@"服务 ID、脚本路径和数据目录不能为空。"}]; return NO; }
#if !PYHOST_AVAILABLE
    if (error) *error = [NSError errorWithDomain:@"PyHost" code:3 userInfo:@{NSLocalizedDescriptionKey:@"此构建未包含 CPython 运行时；插件未启动。"}]; return NO;
#else
    NSString *res = NSBundle.mainBundle.resourcePath, *home = [res stringByAppendingPathComponent:@"python"];
    NSString *stdlib = [home stringByAppendingPathComponent:@"lib/python3.13"], *dynload = [stdlib stringByAppendingPathComponent:@"lib-dynload"];
    BOOL runtimeOK = [NSFileManager.defaultManager fileExistsAtPath:path] && [NSFileManager.defaultManager fileExistsAtPath:stdlib] && [NSFileManager.defaultManager fileExistsAtPath:dynload] && [NSFileManager.defaultManager fileExistsAtPath:[home stringByAppendingPathComponent:@"ssl/cert.pem"]] && [NSFileManager.defaultManager fileExistsAtPath:[res stringByAppendingPathComponent:@"host_service_runtime.py"]];
    NSArray *extensions = [NSFileManager.defaultManager contentsOfDirectoryAtPath:dynload error:nil] ?: @[];
    for (NSString *module in @[@"_ssl", @"_socket", @"_hashlib", @"select", @"_struct"]) { BOOL found = NO; for (NSString *file in extensions) if ([file hasPrefix:[module stringByAppendingString:@"."]] && ([file hasSuffix:@".fwork"] || [file hasSuffix:@".so"])) { found = YES; break; } if (!found) runtimeOK = NO; }
    if (!runtimeOK) { if (error) *error = [NSError errorWithDomain:@"PyHost" code:1 userInfo:@{NSLocalizedDescriptionKey:@"Python 运行时不完整：需要插件脚本、python 标准库、设备扩展模块以及 SSL 证书。"}]; return NO; }
    NSError *directoryError = nil;
    if (![NSFileManager.defaultManager createDirectoryAtPath:dataDir withIntermediateDirectories:YES attributes:nil error:&directoryError]) { if (error) *error = directoryError; return NO; }
    PyHostTask *task = [PyHostTask new]; task.identifier = identifier; task.scriptPath = path; task.pythonHome = home; task.dataDir = dataDir; task.port = port; task.arguments = arguments.copy ?: @[];
    pthread_mutex_lock(&gLock);
    if(gInterpreterFailure){NSError *failure=gInterpreterFailure;pthread_mutex_unlock(&gLock);if(error)*error=failure;return NO;}
    PyHostTask *previous = gTasks[identifier];
    if (previous && (previous.running || !previous.threadExited)) { pthread_mutex_unlock(&gLock); if (error) *error = [NSError errorWithDomain:@"PyHost" code:4 userInfo:@{NSLocalizedDescriptionKey:@"该服务已经运行或正在启停。"}]; return NO; }
    if (previous) [gTasks removeObjectForKey:identifier];
    [gTaskFailures removeObjectForKey:identifier];
    task.initializesInterpreter = !gInterpreterReady && !gInterpreterInitializing;
    if (task.initializesInterpreter) gInterpreterInitializing = YES;
    gStartedOnce = YES; gTasks[identifier] = task;
    void *threadContext = (__bridge_retained void *)task;
    pthread_t thread;
    int rc = pthread_create(&thread, NULL, pyThread, threadContext);
    if (rc != 0) { __unused id releasedContext = (__bridge_transfer id)threadContext; if (task.initializesInterpreter) { gInterpreterInitializing = NO; pthread_cond_broadcast(&gCondition); } [gTasks removeObjectForKey:identifier]; pthread_mutex_unlock(&gLock); if (error) *error = [NSError errorWithDomain:@"PyHost" code:5 userInfo:@{NSLocalizedDescriptionKey:[NSString stringWithFormat:@"无法创建 Python 线程 (%d)", rc]}]; return NO; }
    task.thread=thread;
    pthread_detach(thread); pthread_mutex_unlock(&gLock); notifyRuntimeStateChanged(); return YES;
#endif
}

+ (BOOL)stopServiceIdentifier:(NSString *)identifier error:(NSError **)error {
    if (!identifier.length) { if (error) *error = [NSError errorWithDomain:@"PyHost" code:13 userInfo:@{NSLocalizedDescriptionKey:@"服务 ID 不能为空。"}]; return NO; }
    ensureMaps();
#if !PYHOST_AVAILABLE
    if (![NodePluginRuntime.shared stopSessionsForServiceIdentifier:identifier error:error]) return NO;
    return [JSPluginRuntime.shared stopSessionsForServiceIdentifier:identifier error:error];
#else
    pthread_mutex_lock(&gLock); PyHostTask *task = gTasks[identifier];
    if (!task) { pthread_mutex_unlock(&gLock); if (![NodePluginRuntime.shared stopSessionsForServiceIdentifier:identifier error:error]) return NO;if(![JSPluginRuntime.shared stopSessionsForServiceIdentifier:identifier error:error])return NO;pthread_mutex_lock(&gLock);[gTaskFailures removeObjectForKey:identifier];pthread_mutex_unlock(&gLock);notifyRuntimeStateChanged();return YES; }
    task.stopping = YES;
    for (NSUInteger wait = 0; !task.sessionReady && !task.threadExited && wait < 500; wait++) { struct timespec deadline; clock_gettime(CLOCK_REALTIME, &deadline); deadline.tv_nsec += 10000000; if (deadline.tv_nsec >= 1000000000) { deadline.tv_sec++; deadline.tv_nsec -= 1000000000; } pthread_cond_timedwait(&gCondition, &gLock, &deadline); }
    BOOL exited = task.threadExited, ready = task.sessionReady; pthread_mutex_unlock(&gLock);
    if (exited && !task.running) { NSError *failure=nil;if(![JSPluginRuntime.shared stopSessionsForServiceIdentifier:identifier error:&failure]||![NodePluginRuntime.shared stopSessionsForServiceIdentifier:identifier error:&failure]){if(error)*error=failure;return NO;}pthread_mutex_lock(&gLock);[gTaskFailures removeObjectForKey:identifier];pthread_mutex_unlock(&gLock);notifyRuntimeStateChanged();return YES; }
    if (!ready) { if (error) *error = task.error ?: [NSError errorWithDomain:@"PyHost" code:7 userInfo:@{NSLocalizedDescriptionKey:@"Python 初始化尚未完成，请稍后停止。"}]; return NO; }
    PyGILState_STATE gil = PyGILState_Ensure();
    PyObject *result = gServiceRuntime ? PyObject_CallMethod(gServiceRuntime, "stop_session", "sd", identifier.UTF8String, 5.0) : NULL;
    BOOL stopped = result && PyObject_IsTrue(result) > 0; Py_XDECREF(result);
    NSString *message = @"服务管理器尚未就绪，请稍后重试。";
    if (!stopped && gServiceRuntime) { PyObject *detail = PyObject_CallMethod(gServiceRuntime, "last_error", "s", identifier.UTF8String); const char *utf8 = detail && PyUnicode_Check(detail) ? PyUnicode_AsUTF8(detail) : NULL; if (utf8 && *utf8) message = [NSString stringWithUTF8String:utf8]; Py_XDECREF(detail); }
    PyErr_Clear(); PyGILState_Release(gil);
    if (!stopped) { if (error) *error = [NSError errorWithDomain:@"PyHost" code:6 userInfo:@{NSLocalizedDescriptionKey:message}]; pthread_mutex_lock(&gLock); task.stopping = NO; pthread_mutex_unlock(&gLock); return NO; }
    for (NSUInteger attempt = 0; attempt < 500; attempt++) { pthread_mutex_lock(&gLock); exited = task.threadExited; if (exited) { task.running = NO; task.stopping = NO; [gTasks removeObjectForKey:identifier]; } pthread_mutex_unlock(&gLock); if (exited) { NSError *failure=nil;if(![JSPluginRuntime.shared stopSessionsForServiceIdentifier:identifier error:&failure]||![NodePluginRuntime.shared stopSessionsForServiceIdentifier:identifier error:&failure]){if(error)*error=failure;return NO;}notifyRuntimeStateChanged(); return YES; } [NSThread sleepForTimeInterval:.01]; }
    if (error) *error = [NSError errorWithDomain:@"PyHost" code:9 userInfo:@{NSLocalizedDescriptionKey:@"服务线程正在结束，请稍后重试。"}]; return NO;
#endif
}
+ (BOOL)stopWithError:(NSError **)error {
    NSMutableArray *identifiers = [self.runningServiceIdentifiers mutableCopy];
    for(NSString *identifier in NodePluginRuntime.shared.managedServiceIdentifiers)if(![identifiers containsObject:identifier])[identifiers addObject:identifier];
    for(NSString *identifier in JSPluginRuntime.shared.managedServiceIdentifiers)if(![identifiers containsObject:identifier])[identifiers addObject:identifier];
    BOOL success = YES; NSError *first = nil;
    for (NSString *identifier in identifiers) { NSError *failure = nil; if (![self stopServiceIdentifier:identifier error:&failure]) { success = NO; if (!first) first = failure; } }
    if (!success && error) *error = first; return success;
}
+ (void)stop { NSError *error = nil; if (![self stopWithError:&error] && error) emitLog(error.localizedDescription); }

@end
