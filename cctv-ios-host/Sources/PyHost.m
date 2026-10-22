#import "PyHost.h"
#if __has_include(<Python.h>)
#import <Python.h>
#define PYHOST_AVAILABLE 1
#else
#define PYHOST_AVAILABLE 0
#endif
#import <unistd.h>
#import <pthread.h>

static BOOL gRunning = NO;
static NSInteger gPort = 0;
static int gPipeFD[2] = {-1, -1};
static pthread_t gThread;
static char gScriptPath[1024];
static char gDataDir[1024];
static char gArgvPort[16];

@interface PyHost ()
@end

@implementation PyHost

+ (BOOL)running { return gRunning; }
+ (NSInteger)port { return gPort; }
static void (^gLogHandler)(NSString *) = nil;
+ (void)setLogHandler:(void (^)(NSString *))h { gLogHandler = [h copy]; }
+ (void (^)(NSString *))logHandler { return gLogHandler; }

#pragma mark - stdout 转发

static void *readerThread(void *ctx) {
    char buf[1024];
    ssize_t n;
    while ((n = read(gPipeFD[0], buf, sizeof(buf) - 1)) > 0) {
        buf[n] = '\0';
        NSString *line = [[NSString alloc] initWithUTF8String:buf];
        if (!line.length) continue;
        void (^h)(NSString *) = gLogHandler;
        if (h) h([line stringByTrimmingCharactersInSet:NSCharacterSet.newlineCharacterSet]);
    }
    return NULL;
}

#pragma mark - Python 线程

#if PYHOST_AVAILABLE
static void *pyThread(void *ctx) {
    char home[1024];
    @autoreleasepool {
        NSString *res = [[NSBundle mainBundle] resourcePath];
        NSString *pyhome = [res stringByAppendingPathComponent:@"python"];
        strncpy(home, pyhome.UTF8String, sizeof(home) - 1);
    }
    setenv("PYTHONHOME", home, 1);
    setenv("PYTHONPATH", home, 1);
    setenv("PYTHONUNBUFFERED", "1", 1);
    setenv("YSP_DATA_DIR", gDataDir, 1);

    NSString *bootstrap = [NSString stringWithFormat:
        @"import sys, runpy\n"
        @"sys.argv = [%s, '%s', '--bind', '127.0.0.1', '--no-engine', '--data-dir', '%s']\n",
        gScriptPath, gArgvPort, gDataDir];
    NSString *run = [NSString stringWithFormat:@"runpy.run_path('%s', run_name='__main__')\n", gScriptPath];

    PyStatus status;
    PyConfig config;
    PyConfig_InitPythonConfig(&config);
    config.install_signal_handlers = 0;
    status = PyConfig_SetBytesString(&config, &config.home, home);
    if (!PyStatus_Exception(status)) {
        status = Py_InitializeFromConfig(&config);
    }
    PyConfig_Clear(&config);
    if (PyStatus_Exception(status)) {
        NSString *msg = [NSString stringWithFormat:@"Py_Initialize 失败: %s", status.err_msg ?: "unknown"];
        void (^h)(NSString *) = gLogHandler;
        if (h) h(msg);
        gRunning = NO;
        return NULL;
    }
    PyRun_SimpleString("import sys\nsys.path.insert(0, '.')\n");
    int rc1 = PyRun_SimpleString(bootstrap.UTF8String);
    int rc2 = rc1 == 0 ? PyRun_SimpleString(run.UTF8String) : rc1;
    NSString *msg = [NSString stringWithFormat:@"插件进程退出，rc=%d", rc2];
    void (^h)(NSString *) = gLogHandler;
    if (h) h(msg);
    gRunning = NO;
    return NULL;
}

#endif /* PYHOST_AVAILABLE */

#pragma mark - 对外接口

+ (BOOL)startWithScript:(NSString *)scriptName
                   port:(NSInteger)port
                dataDir:(NSString *)dataDir
                  error:(NSError **)error {
    if (gRunning) return YES;

    NSString *res = [[NSBundle mainBundle] resourcePath];
    NSString *script = [res stringByAppendingPathComponent:scriptName];
    NSString *home = [res stringByAppendingPathComponent:@"python"];
    if (![[NSFileManager defaultManager] fileExistsAtPath:script]) {
        if (error) *error = [NSError errorWithDomain:@"PyHost" code:1 userInfo:@{NSLocalizedDescriptionKey: @"脚本未打包"}];
        return NO;
    }
    if (![[NSFileManager defaultManager] fileExistsAtPath:home]) {
        if (error) *error = [NSError errorWithDomain:@"PyHost" code:2 userInfo:@{NSLocalizedDescriptionKey: @"标准库未打包"}];
        return NO;
    }
    NSError *e = nil;
    [[NSFileManager defaultManager] createDirectoryAtPath:dataDir
                              withIntermediateDirectories:YES attributes:nil error:&e];

#if PYHOST_AVAILABLE
    strncpy(gScriptPath, script.UTF8String, sizeof(gScriptPath) - 1);
    strncpy(gDataDir, dataDir.UTF8String, sizeof(gDataDir) - 1);
    snprintf(gArgvPort, sizeof(gArgvPort), "%ld", (long)port);
    gPort = port;
    gRunning = YES;

    if (pipe(gPipeFD) == 0) {
        dup2(gPipeFD[1], STDOUT_FILENO);
        dup2(gPipeFD[1], STDERR_FILENO);
        pthread_t r;
        pthread_create(&r, NULL, readerThread, NULL);
        pthread_detach(r);
    }
#if PYHOST_AVAILABLE
    pthread_create(&gThread, NULL, pyThread, NULL);
    return YES;
#else
    if (error) *error = [NSError errorWithDomain:@"PyHost" code:3
                                        userInfo:@{NSLocalizedDescriptionKey: @"本次构建未包含 Python 运行时"}];
    gRunning = NO;
    return NO;
#endif
}

+ (void)stop {
    // 插件的 HTTP 服务线程无法从外部安全终止；这里只标记状态并关闭管道
    gRunning = NO;
    if (gPipeFD[0] >= 0) { close(gPipeFD[0]); gPipeFD[0] = -1; }
    if (gPipeFD[1] >= 0) { close(gPipeFD[1]); gPipeFD[1] = -1; }
}

@end
