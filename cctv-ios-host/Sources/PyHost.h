#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 内置 CPython 宿主：启动后在同一进程内运行 Python 插件脚本（如 ysp-live）
@interface PyHost : NSObject

@property (class, nonatomic, readonly) BOOL running;
@property (class, nonatomic, readonly) BOOL startedOnce;
@property (class, nonatomic, readonly) NSInteger port;
@property (class, nonatomic, readonly, nullable) NSError *startupError;

/// stdout/stderr 回调（后台线程调用）
+ (void)setLogHandler:(nullable void (^)(NSString *line))handler;

/// 启动插件；scriptName 为 App 资源里的脚本文件名
+ (BOOL)startWithScript:(NSString *)scriptName
                   port:(NSInteger)port
                dataDir:(NSString *)dataDir
                  error:(NSError **)error;

+ (BOOL)startScriptAtPath:(NSString *)path port:(NSInteger)port dataDir:(NSString *)dataDir arguments:(nullable NSArray<NSString *> *)arguments error:(NSError **)error;

+ (BOOL)stopWithError:(NSError **)error;
+ (void)stop;

@end

NS_ASSUME_NONNULL_END
